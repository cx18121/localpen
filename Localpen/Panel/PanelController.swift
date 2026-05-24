import AppKit
import SwiftUI
import Observation
import Carbon.HIToolbox
import os

@MainActor
@Observable
final class PanelController {
    var state: PanelState = .hidden
    /// The editable working text. Initialized from the captured selection on
    /// hotkey; bound to the input TextEditor in .empty/.captured states so
    /// the user can fix typos / rewrite before picking an action.
    var inputText: String = ""
    /// Index into ActionMenuView's row list (Action.fixed + [.custom]).
    /// Lives here so it survives state transitions and is the single source
    /// of truth for keyboard navigation.
    var focusedActionIndex: Int = 1   // Polish default
    /// Tracks whether the user last drove the panel with the keyboard or the
    /// mouse. `.onHover` only updates focus when the last input was mouse —
    /// otherwise an idle mouse parked over a different row would steal focus
    /// from arrow-key navigation.
    var lastInputSource: InputSource = .keyboard
    enum InputSource { case keyboard, mouse }

    static let panelSize = NSSize(width: 360, height: 480)
    static let panelEdgeMargin: CGFloat = 24

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private let textIO: TextIO
    @ObservationIgnored private let streaming: StreamingClient
    @ObservationIgnored private let persistence: Persistence?
    @ObservationIgnored private let registry: ModelRegistry
    @ObservationIgnored private weak var llamaServer: LlamaServerController?
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    @ObservationIgnored private var activeCapture: TextIO.Capture?
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyTime: ContinuousClock.Instant?
    @ObservationIgnored private var clickOutsideMonitor: Any?
    @ObservationIgnored private var mouseInputMonitor: Any?
    @ObservationIgnored private var pendingInteraction: Interaction?
    @ObservationIgnored private var sessionID: UInt64 = 0

    static let menuItems: [Action] = Action.fixed + [.custom("")]

    @ObservationIgnored let openSettings: () -> Void

    init(textIO: TextIO,
         streaming: StreamingClient,
         persistence: Persistence?,
         registry: ModelRegistry,
         llamaServer: LlamaServerController?,
         openSettings: @escaping () -> Void) {
        self.textIO = textIO
        self.streaming = streaming
        self.persistence = persistence
        self.registry = registry
        self.llamaServer = llamaServer
        self.openSettings = openSettings
    }

    deinit {
        if let mon = clickOutsideMonitor { NSEvent.removeMonitor(mon) }
        if let mon = mouseInputMonitor { NSEvent.removeMonitor(mon) }
    }

    // MARK: - Entry / dismiss

    func toggleFromHotkey() {
        if state.isVisible { return }
        Task { await captureAndShow() }
    }

    func dismiss() {
        cancelStreaming()
        persistRejectedIfNeeded()
        if let cap = activeCapture {
            textIO.restoreClipboard(cap)
        }
        let mySession = sessionID
        hidePanelAnimated { [weak self] in
            guard let self, self.sessionID == mySession else { return }
            self.state = .hidden
            self.activeCapture = nil
            self.hotkeyTime = nil
            self.pendingInteraction = nil
        }
    }

    // MARK: - Unified keyboard handler

    func handleKeyDown(_ event: NSEvent) -> Bool {
        lastInputSource = .keyboard
        let code = Int(event.keyCode)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)

        switch state {
        case .hidden:
            return false

        case .empty, .captured:
            // Both states render InputEditor + ActionMenu; share nav.
            switch code {
            case kVK_UpArrow:
                focusedActionIndex = (focusedActionIndex - 1 + Self.menuItems.count) % Self.menuItems.count
                return true
            case kVK_DownArrow:
                focusedActionIndex = (focusedActionIndex + 1) % Self.menuItems.count
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                pick(Self.menuItems[focusedActionIndex])
                return true
            case kVK_Escape:
                dismiss()
                return true
            default:
                return false
            }

        case .customPrompt:
            if code == kVK_Escape { backToMenu(); return true }
            return false

        case .generating:
            if code == kVK_Escape { backToMenu(); return true }
            return false

        case .result(_, _, _, let isEditing):
            if isEditing {
                if code == kVK_Escape { setEditing(false); return true }
                if (code == kVK_Return || code == kVK_ANSI_KeypadEnter) && cmd {
                    acceptResult()
                    return true
                }
                if (code == kVK_Return || code == kVK_ANSI_KeypadEnter) && !shift {
                    setEditing(false)
                    return true
                }
                return false
            } else {
                switch code {
                case kVK_Escape:
                    backToMenu()
                    return true
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    acceptResult()
                    return true
                default:
                    return false
                }
            }

        case .error:
            if code == kVK_Escape { backToMenu(); return true }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                retryFromError()
                return true
            }
            return false
        }
    }

    // MARK: - State transitions

    func pick(_ action: Action) {
        switch action {
        case .custom:
            state = .customPrompt(selectionWithCurrentInput())
        default:
            startGeneration(action: action, selection: selectionWithCurrentInput())
        }
    }

    func submitCustomPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startGeneration(action: .custom(trimmed))
    }

    func backToMenu() {
        cancelStreaming()
        persistRejectedIfNeeded()
        pendingInteraction = nil
        if let sel = currentSelection() {
            state = .captured(sel)
        } else {
            state = .empty
        }
    }

    func acceptResult() {
        guard case .result(let sel, let action, let text, _) = state else { return }
        let snapshot = activeCapture
        let mySession = sessionID

        if var pending = pendingInteraction {
            pending.accepted = true
            pending.editedOutput = (text == pending.modelOutput) ? nil : text
            persistInteraction(pending)
        } else {
            persistInteraction(buildInteraction(selection: sel, action: action, output: text, accepted: true, edited: nil))
        }
        pendingInteraction = nil

        Task {
            let result: TextIO.PasteBackResult
            if let cap = snapshot {
                result = await textIO.pasteBack(result: text, capture: cap)
            } else {
                result = .pasted
            }
            await MainActor.run {
                guard self.sessionID == mySession else { return }
                if result == .skipped {
                    self.state = .error(.pasteBackFallback, prior: PanelState.ErrorContext(selection: sel, action: action))
                } else {
                    self.hidePanelAnimated { [weak self] in
                        guard let self, self.sessionID == mySession else { return }
                        self.state = .hidden
                    }
                    self.activeCapture = nil
                    self.hotkeyTime = nil
                }
            }
        }
    }

    func setEditing(_ editing: Bool) {
        if case .result(let sel, let action, let text, _) = state {
            state = .result(sel, action, finalResult: text, isEditing: editing)
        }
    }

    func updateEditedResult(_ newText: String) {
        if case .result(let sel, let action, _, let editing) = state {
            state = .result(sel, action, finalResult: newText, isEditing: editing)
        }
    }

    func retryFromError() {
        guard case .error(let err, let prior) = state else { return }
        switch err {
        case .serverDown:
            Task { @MainActor [weak self] in
                await self?.restartServer()
                if let action = prior?.action {
                    self?.startGeneration(action: action, selection: prior?.selection)
                } else {
                    self?.backToMenu()
                }
            }
        case .timeout, .network:
            if let action = prior?.action {
                startGeneration(action: action, selection: prior?.selection)
            } else {
                backToMenu()
            }
        case .pasteBackFallback:
            cancelStreaming()
            persistRejectedIfNeeded()
            let mySession = sessionID
            hidePanelAnimated { [weak self] in
                guard let self, self.sessionID == mySession else { return }
                self.state = .hidden
                self.activeCapture = nil
                self.pendingInteraction = nil
            }
        case .diskFull:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            backToMenu()
        case .hotkeyConflict:
            openSettings()
            backToMenu()
        }
    }

    private func restartServer() async {
        guard let server = llamaServer, let descriptor = registry.activeModel else { return }
        server.stop()
        let modelPath = registry.modelPath(for: descriptor).path
        try? await server.start(modelPath: modelPath, contextSize: descriptor.contextSize)
    }

    // MARK: - Capture + show

    private func captureAndShow() async {
        sessionID += 1
        let mySession = sessionID
        hotkeyTime = ContinuousClock.now
        focusedActionIndex = 1
        lastInputSource = .keyboard

        let capture = await textIO.captureSelection()
        guard sessionID == mySession else { return }
        activeCapture = capture

        // Seed the editable input field with the captured selection (if any).
        inputText = capture.selection ?? ""

        if let text = capture.selection, !text.isEmpty {
            let sel = Selection(
                text: text,
                sourceBundleID: capture.sourceBundleID,
                sourceAppName: capture.sourceAppName
            )
            state = .captured(sel)
        } else {
            state = .empty
        }
        showPanel()
    }

    /// Builds a Selection that reflects the user's current edits to inputText,
    /// preserving the source-app metadata from the original capture.
    private func selectionWithCurrentInput() -> Selection? {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Selection(
            text: inputText,
            sourceBundleID: activeCapture?.sourceBundleID,
            sourceAppName: activeCapture?.sourceAppName
        )
    }

    /// Fixed sidebar anchor — right edge of the screen the cursor is on,
    /// vertically centered. Multi-monitor aware (works regardless of which
    /// display the user is currently working on).
    private func sidebarOrigin() -> NSPoint {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.maxX - Self.panelSize.width - Self.panelEdgeMargin,
            y: frame.midY - Self.panelSize.height / 2
        )
    }

    private func showPanel() {
        let rect = NSRect(origin: .zero, size: Self.panelSize)

        if panel == nil {
            let p = FloatingPanel(contentRect: rect)
            p.onKeyDown = { [weak self] event in
                self?.handleKeyDown(event) ?? false
            }
            let host = NSHostingController(rootView: PanelView(controller: self))
            p.contentViewController = host
            panel = p
            installObservers()
        }

        let origin = sidebarOrigin()
        let startOrigin = NSPoint(x: origin.x, y: origin.y + 8)
        panel?.setFrameOrigin(startOrigin)
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        panel?.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel?.animator().setFrameOrigin(origin)
            panel?.animator().alphaValue = 1
        }
    }

    private func hidePanelAnimated(completion: (@Sendable @MainActor () -> Void)? = nil) {
        guard let panel else {
            completion?()
            return
        }
        let origin = panel.frame.origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 4))
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrameOrigin(origin)
                completion?()
            }
        })
    }

    private func installObservers() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isVisible else { return }
                self.dismiss()
            }
        }
        // Track input source — any mouse event in our own app means "mouse".
        // Local monitor delivers on the main thread, so we can set the
        // @MainActor-isolated property synchronously here. Doing this via
        // a Task created a race where a delayed mouse-set could land after
        // a later keyboard-set and overwrite it.
        mouseInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastInputSource = .mouse
            }
            return event
        }
    }

    // MARK: - Streaming

    private func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func startGeneration(action: Action, selection explicitSel: Selection? = nil) {
        let sel = explicitSel ?? currentSelection()
        state = .generating(sel, action, partial: "")
        cancelStreaming()
        streamingTask = Task { @MainActor [weak self] in
            await self?.runStream(action: action, selection: sel)
        }
    }

    private func armWatchdog(action: Action, selection: Selection?) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.streamingTask?.cancel()
            self.state = .error(.timeout, prior: PanelState.ErrorContext(selection: selection, action: action))
        }
    }

    private func runStream(action: Action, selection: Selection?) async {
        let userText = selection?.text ?? ""
        let systemPrompt = registry.systemPrompt(for: action)
        let userPrompt: String = {
            if case let .custom(instruction) = action {
                if userText.isEmpty { return instruction }
                return "Instruction: \(instruction)\n\nText:\n\(userText)"
            }
            return userText
        }()

        armWatchdog(action: action, selection: selection)
        defer { watchdogTask?.cancel() }

        var partial = ""
        var firstTokenLogged = false
        do {
            let sampling = registry.activeModel?.sampling
            for try await token in streaming.complete(systemPrompt: systemPrompt, userText: userPrompt, sampling: sampling) {
                if Task.isCancelled { return }
                if !firstTokenLogged, let t = hotkeyTime {
                    let elapsed = ContinuousClock.now - t
                    log.info("hotkey→first-token: \(elapsed)")
                    firstTokenLogged = true
                }
                partial += token
                state = .generating(selection, action, partial: partial)
                armWatchdog(action: action, selection: selection)
            }
            if Task.isCancelled { return }
            pendingInteraction = buildInteraction(
                selection: selection, action: action, output: partial,
                accepted: false, edited: nil
            )
            state = .result(selection, action, finalResult: partial, isEditing: false)
        } catch {
            if Task.isCancelled { return }
            let ns = error as NSError
            let ctx = PanelState.ErrorContext(selection: selection, action: action)
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotConnectToHost {
                state = .error(.serverDown(reason: ns.localizedDescription), prior: ctx)
            } else {
                state = .error(.network, prior: ctx)
            }
        }
    }

    // MARK: - Persistence

    private func buildInteraction(selection: Selection?, action: Action, output: String?, accepted: Bool, edited: String?) -> Interaction {
        var customPrompt: String? = nil
        if case let .custom(text) = action { customPrompt = text }
        return Interaction(
            id: nil,
            timestamp: Int64(Date().timeIntervalSince1970),
            sourceApp: selection?.sourceBundleID,
            selection: selection?.text,
            action: action.rawValue,
            customPrompt: customPrompt,
            modelID: registry.activeModelID,
            modelOutput: output,
            accepted: accepted,
            editedOutput: edited
        )
    }

    private func persistInteraction(_ interaction: Interaction) {
        guard let persistence else { return }
        Task.detached(priority: .background) {
            await persistence.save(interaction)
        }
    }

    private func persistRejectedIfNeeded() {
        if let pending = pendingInteraction {
            persistInteraction(pending)
        }
    }

    // MARK: - Helpers

    func currentSelection() -> Selection? {
        switch state {
        case .captured(let s):                  return s
        case .customPrompt(let s):              return s
        case .generating(let s, _, _):          return s
        case .result(let s, _, _, _):           return s
        case .error(_, let prior):              return prior?.selection
        case .empty, .hidden:                   return nil
        }
    }
}
