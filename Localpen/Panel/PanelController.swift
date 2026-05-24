import AppKit
import SwiftUI
import Observation
import os

@MainActor
@Observable
final class PanelController {
    var state: PanelState = .hidden

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private let textIO: TextIO
    @ObservationIgnored private let streaming: StreamingClient
    @ObservationIgnored private let persistence: Persistence?
    @ObservationIgnored private let registry: ModelRegistry
    @ObservationIgnored private let anchorStore: AnchorStore
    @ObservationIgnored private weak var llamaServer: LlamaServerController?
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    @ObservationIgnored private var activeCapture: TextIO.Capture?
    @ObservationIgnored private var streamingTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyTime: ContinuousClock.Instant?
    @ObservationIgnored private var moveObserver: Any?
    @ObservationIgnored private var clickOutsideMonitor: Any?
    @ObservationIgnored private var pendingInteraction: Interaction?
    @ObservationIgnored private var sessionID: UInt64 = 0

    init(textIO: TextIO,
         streaming: StreamingClient,
         persistence: Persistence?,
         registry: ModelRegistry,
         anchorStore: AnchorStore,
         llamaServer: LlamaServerController?) {
        self.textIO = textIO
        self.streaming = streaming
        self.persistence = persistence
        self.registry = registry
        self.anchorStore = anchorStore
        self.llamaServer = llamaServer
    }

    deinit {
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
        if let mon = clickOutsideMonitor { NSEvent.removeMonitor(mon) }
    }

    // MARK: - Entry / dismiss

    func toggleFromHotkey() {
        // Per DESIGN.md §5.5: hotkey re-press while open is a no-op (avoid accidental dismiss).
        if state.isVisible { return }
        Task { await captureAndShow() }
    }

    func dismiss() {
        cancelStreaming()
        persistRejectedIfNeeded()
        // P1.1: restore the user's clipboard on EVERY dismissal path.
        // pasteBack handles its own restoration when it succeeds; dismiss
        // covers Esc / click-outside / explicit dismissal.
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

    // MARK: - State transitions

    func pick(_ action: Action) {
        switch action {
        case .custom:
            state = .customPrompt(currentSelection())
        default:
            startGeneration(action: action)
        }
    }

    func submitCustomPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startGeneration(action: .custom(trimmed))
    }

    func backToMenu() {
        cancelStreaming()
        // P1.6: rejected results MUST be persisted before we clear them
        // (ADR 0006 requires the rejection signal for Phase 2 memory inference).
        persistRejectedIfNeeded()
        pendingInteraction = nil
        if let sel = currentSelection() {
            state = .captured(sel)
        } else {
            state = .empty
        }
    }

    func handleEscape() {
        switch state {
        case .hidden, .empty, .captured:
            dismiss()
        case .customPrompt, .generating, .result, .error:
            backToMenu()
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
                // P1.4: only act if our session is still current.
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

    // MARK: - Error retry

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
            // Result is on the clipboard; just dismiss (skip clipboard restore — user wants the result).
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
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

        let capture = await textIO.captureSelection()
        // P1.4: bail if a newer session has started.
        guard sessionID == mySession else { return }
        activeCapture = capture

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

    private func showPanel() {
        let view = PanelView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 360, height: 320)
        hosting.frame = rect

        if panel == nil {
            panel = FloatingPanel(contentRect: rect)
            installMoveObserver()
        }
        panel?.contentView = hosting

        let screen = NSScreen.main
        let origin = anchorStore.read(bundleID: activeCapture?.sourceBundleID, screen: screen)
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
            // Animation completion fires on the main thread but is typed as
            // nonisolated by the API. Hop to MainActor cleanly via Task.
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrameOrigin(origin)
                completion?()
            }
        })
    }

    private func installMoveObserver() {
        guard let panel else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.persistAnchor() }
        }
        // P2: click-outside dismiss. Global monitor sees clicks in OTHER apps
        // (the source app, the dock, etc.) and dismisses the panel.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isVisible else { return }
                self.dismiss()
            }
        }
    }

    private func persistAnchor() {
        guard let panel else { return }
        anchorStore.write(
            bundleID: activeCapture?.sourceBundleID,
            screen: panel.screen ?? NSScreen.main,
            origin: panel.frame.origin
        )
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
