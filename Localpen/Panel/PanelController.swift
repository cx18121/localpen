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

    /// The in-flight capture→generate→accept attempt, or nil when hidden. Holds
    /// everything scoped to one summon (capture, tasks, pending result) so a
    /// "did the world move on?" check is `current === session`, not a token.
    @ObservationIgnored private var current: PanelSession?
    /// Monotonic session-ID source. Also detects supersession during the
    /// pre-capture await, before a PanelSession object exists yet.
    @ObservationIgnored private var sessionCounter: UInt64 = 0
    @ObservationIgnored private var clickOutsideMonitor: Any?
    @ObservationIgnored private var mouseInputMonitor: Any?

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
        current?.cancelStreaming()
        flushPendingAsRejected()
        if let session = current {
            textIO.restoreClipboard(session.capture)
        }
        state = .hidden
        current = nil
        hidePanelAnimated()
    }

    // MARK: - Unified keyboard handler

    func handleKeyDown(_ event: NSEvent) -> Bool {
        lastInputSource = .keyboard
        let code = Int(event.keyCode)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let shift = mods.contains(.shift)

        guard case .visible(_, let phase) = state else { return false }
        switch phase {
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

        case .result(_, let isEditing):
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
            state = .visible(PanelContext(selection: selectionWithCurrentInput()), .customPrompt)
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
        current?.cancelStreaming()
        flushPendingAsRejected()
        if let sel = currentSelection() {
            state = .visible(PanelContext(selection: sel), .captured)
        } else {
            state = .visible(PanelContext(), .empty)
        }
    }

    func acceptResult() {
        guard case .visible(let ctx, .result(let text, _)) = state,
              let action = ctx.action,
              let session = current else { return }
        let sel = ctx.selection
        let capture = session.capture

        if var pending = session.pendingInteraction {
            pending.accepted = true
            pending.editedOutput = (text == pending.modelOutput) ? nil : text
            persistInteraction(pending)
        } else {
            persistInteraction(buildInteraction(selection: sel, action: action, output: text, accepted: true, edited: nil))
        }
        session.pendingInteraction = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.textIO.pasteBack(result: text, capture: capture)
            guard self.current === session else { return }
            if result == .skipped {
                self.state = .visible(PanelContext(selection: sel, action: action), .error(.pasteBackFallback))
            } else {
                self.state = .hidden
                self.current = nil
                self.hidePanelAnimated()
            }
        }
    }

    func setEditing(_ editing: Bool) {
        guard case .visible(let ctx, .result(let text, _)) = state else { return }
        state = .visible(ctx, .result(finalResult: text, isEditing: editing))
    }

    func updateEditedResult(_ newText: String) {
        guard case .visible(let ctx, .result(_, let editing)) = state else { return }
        state = .visible(ctx, .result(finalResult: newText, isEditing: editing))
    }

    func retryFromError() {
        guard case .visible(let ctx, .error(let err)) = state else { return }
        switch err {
        case .serverDown:
            Task { @MainActor [weak self] in
                await self?.restartServer()
                if let action = ctx.action {
                    self?.startGeneration(action: action, selection: ctx.selection)
                } else {
                    self?.backToMenu()
                }
            }
        case .timeout, .network:
            if let action = ctx.action {
                startGeneration(action: action, selection: ctx.selection)
            } else {
                backToMenu()
            }
        case .pasteBackFallback:
            current?.cancelStreaming()
            flushPendingAsRejected()
            state = .hidden
            current = nil
            hidePanelAnimated()
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
        sessionCounter += 1
        let myID = sessionCounter
        let hotkeyTime = ContinuousClock.now
        focusedActionIndex = 1
        lastInputSource = .keyboard

        let capture = await textIO.captureSelection()
        guard sessionCounter == myID else { return }   // superseded during capture

        let session = PanelSession(id: myID, capture: capture, hotkeyTime: hotkeyTime)
        current = session

        // Seed the editable input field with the captured selection (if any).
        inputText = capture.selection ?? ""

        if let text = capture.selection, !text.isEmpty {
            let sel = Selection(
                text: text,
                sourceBundleID: capture.sourceBundleID,
                sourceAppName: capture.sourceAppName
            )
            state = .visible(PanelContext(selection: sel), .captured)
        } else {
            state = .visible(PanelContext(), .empty)
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
            sourceBundleID: current?.capture.sourceBundleID,
            sourceAppName: current?.capture.sourceAppName
        )
    }

    /// Fixed sidebar anchor — right edge of the screen the cursor is on. Returns
    /// the panel's TOP-LEFT corner: the panel grows downward from a constant top
    /// edge so it sizes to its content without jumping vertically between states.
    /// Multi-monitor aware (anchors on whichever display the cursor is on).
    private func sidebarTopLeft() -> NSPoint {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.maxX - Self.panelSize.width - Self.panelEdgeMargin,
            y: frame.midY + Self.panelSize.height / 2   // fixed top edge
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

        guard let panel else { return }
        let anchor = sidebarTopLeft()
        // Pin the top edge so content-driven resizes grow downward, not jump.
        panel.pinnedTopY = anchor.y
        let finalOrigin = NSPoint(x: anchor.x, y: anchor.y - panel.frame.height)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(finalOrigin)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        // Slide in a touch from the right edge while fading up — the panel
        // "presents" itself rather than blinking into place.
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x + 16, y: finalOrigin.y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanelAnimated() {
        guard let panel else { return }
        let origin = panel.frame.origin

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrameOrigin(NSPoint(x: origin.x + 12, y: origin.y))
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                // The state already moved to .hidden synchronously. Only finish
                // the hide if nothing re-summoned the panel meanwhile; showPanel()
                // owns alpha/origin when it did.
                guard let self, !self.state.isVisible else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrameOrigin(origin)
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

    private func startGeneration(action: Action, selection explicitSel: Selection? = nil) {
        guard let session = current else { return }
        let sel = explicitSel ?? currentSelection()
        state = .visible(PanelContext(selection: sel, action: action), .generating(partial: ""))
        session.cancelStreaming()
        session.streamingTask = Task { @MainActor [weak self] in
            await self?.runStream(action: action, selection: sel)
        }
    }

    private func armWatchdog(action: Action, selection: Selection?) {
        guard let session = current else { return }
        session.watchdogTask?.cancel()
        session.watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.current?.streamingTask?.cancel()
            self.state = .visible(PanelContext(selection: selection, action: action), .error(.timeout))
        }
    }

    private func runStream(action: Action, selection: Selection?) async {
        let systemPrompt = registry.systemPrompt(for: action)
        let userPrompt = ActionPrompts.userMessage(for: action, text: selection?.text ?? "")

        armWatchdog(action: action, selection: selection)
        defer { current?.watchdogTask?.cancel() }

        var partial = ""
        var firstTokenLogged = false
        do {
            let sampling = registry.activeModel?.sampling
            for try await token in streaming.complete(systemPrompt: systemPrompt, userText: userPrompt, sampling: sampling) {
                if Task.isCancelled { return }
                if !firstTokenLogged, let t = current?.hotkeyTime {
                    let elapsed = ContinuousClock.now - t
                    log.info("hotkey→first-token: \(elapsed)")
                    firstTokenLogged = true
                }
                partial += token
                state = .visible(PanelContext(selection: selection, action: action), .generating(partial: partial))
                armWatchdog(action: action, selection: selection)
            }
            if Task.isCancelled { return }
            current?.pendingInteraction = buildInteraction(
                selection: selection, action: action, output: partial,
                accepted: false, edited: nil
            )
            state = .visible(PanelContext(selection: selection, action: action), .result(finalResult: partial, isEditing: false))
        } catch {
            if Task.isCancelled { return }
            state = .visible(PanelContext(selection: selection, action: action), .error(PanelError(streamingError: error)))
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

    /// Persists the current session's completed-but-unaccepted result as
    /// rejected, then clears it. The single choke point for "we left a result
    /// without accepting it" — every such transition routes through here.
    private func flushPendingAsRejected() {
        guard let session = current, let pending = session.pendingInteraction else { return }
        persistInteraction(pending)
        session.pendingInteraction = nil
    }

    // MARK: - Helpers

    func currentSelection() -> Selection? {
        state.context?.selection
    }
}
