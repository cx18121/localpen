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
    /// The text streamed so far during `.generating`. Kept separate from
    /// PanelState so each token re-renders only the result region (via
    /// StreamingResultView) rather than the whole panel.
    var streamingText: String = ""
    /// The live conversation when in `.conversing`, else nil. ConversationView observes it.
    var conversation: Conversation?
    /// Recent threads for the history list, loaded on demand in `.history`.
    var recentThreads: [ThreadSummary] = []
    /// Incremented to request keyboard focus on the input field (Tab from the
    /// menu). InputEditor focuses itself when this changes. Initial open
    /// auto-focuses via the editor's onAppear.
    var inputFocusTick: Int = 0
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
    /// True for a brief beat right after ⌘C copies the result, so the toolbar
    /// can show a "copied" confirmation. Reset by `flashCopied`.
    var justCopied: Bool = false
    @ObservationIgnored private var copyFlashTask: Task<Void, Never>?

    static let panelSize = NSSize(width: 400, height: 480)
    static let panelEdgeMargin: CGFloat = 24

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private let textIO: TextIO
    @ObservationIgnored private let streaming: StreamingClient
    @ObservationIgnored private let persistence: Persistence?
    @ObservationIgnored private let registry: ModelRegistry
    @ObservationIgnored private let conversationStore: ConversationStore?
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

    static let menuItems: [Action] = Action.fixed + [.respond(""), .custom("")]

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
        self.conversationStore = persistence.map { ConversationStore(dbQueue: $0.dbQueue) }
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
        // Pressing the hotkey again while the panel is open dismisses it — the
        // name promises a toggle, and reaching for Esc/click-away to undo your
        // own hotkey is a daily-use papercut.
        if state.isVisible { dismiss(); return }
        Task { await captureAndShow() }
    }

    func dismiss() {
        current?.cancelStreaming()
        // Capture the on-screen result before flushing — flushPendingAsRejected
        // clears the pending interaction.
        let resultText = displayedResultText()
        flushPendingAsRejected()
        if let session = current {
            if let resultText {
                // A finished result is showing (or was just ⌘C-copied). Leave it
                // on the clipboard so dismissing — including the click-away you'd
                // naturally make to go paste it — doesn't wipe it back to the
                // original captured selection.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resultText, forType: .string)
            } else {
                textIO.restoreClipboard(session.capture)
            }
        }
        state = .hidden
        current = nil
        hidePanelAnimated()
    }

    /// The finished result text if the panel is currently showing one, else nil.
    /// Drives the clipboard end-state on dismiss (see `dismiss`).
    private func displayedResultText() -> String? {
        if case .visible(_, .result(let text, _)) = state { return text }
        return nil
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
                focusedActionIndex = nextSelectableIndex(from: focusedActionIndex, step: -1)
                return true
            case kVK_DownArrow:
                focusedActionIndex = nextSelectableIndex(from: focusedActionIndex, step: 1)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                pick(Self.menuItems[focusedActionIndex])
                return true
            case kVK_Tab:
                inputFocusTick += 1   // move focus up into the input field
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

        case .conversing:
            if code == kVK_Escape { dismiss(); return true }
            return false

        case .history:
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
                case kVK_Tab:
                    setEditing(true)   // Tab into the result to edit it
                    return true
                case kVK_ANSI_C where cmd:
                    copyResult()       // ⌘C copies the result to the clipboard
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
        if case .respond = action, !respondEnabled { return }
        switch action {
        case .custom, .respond:
            // Compose phase always carries its action in the context so submit,
            // the toolbar, accept, and persistence can all read it. Without this
            // the Respond flow silently runs as Custom.
            state = .visible(PanelContext(selection: selectionWithCurrentInput(), action: action), .customPrompt)
        default:
            startGeneration(action: action, selection: selectionWithCurrentInput())
        }
    }

    /// Validates and dispatches a compose-phase submission. Reads the action the
    /// compose view was entered with from `ctx.action`, lets `Action.fromCompose`
    /// decide whether to proceed (empty allowed for Respond, rejected for Custom),
    /// and starts generation. A no-op if there's no compose context/action.
    func submitCompose(_ text: String) {
        guard case .visible(let ctx, .customPrompt) = state, let base = ctx.action else { return }
        guard let action = Action.fromCompose(base: base, text: text) else { return }
        startGeneration(action: action, selection: ctx.selection)
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

        // Persist as accepted (reuse the pending interaction if present).
        if var pending = session.pendingInteraction {
            pending.accepted = true
            pending.editedOutput = (text == pending.modelOutput) ? nil : text
            persistInteraction(pending)
        } else {
            persistInteraction(buildInteraction(selection: sel, action: action, output: text, accepted: true, edited: nil))
        }
        session.pendingInteraction = nil

        switch action.operationClass {
        case .create:
            // A new artifact: leave it on the clipboard, never paste back over
            // the source. Bypasses pasteBack and the .pasteBackFallback state.
            writeToClipboard(text)
            state = .hidden
            current = nil
            hidePanelAnimated()
        case .revise:
            let capture = session.capture
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
    }

    /// Writes `text` to the general pasteboard as the sole string item.
    private func writeToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies the current result to the clipboard without pasting it back into
    /// the source app (⌘C), for when the user wants it elsewhere.
    func copyResult() {
        guard case .visible(_, .result(let text, _)) = state else { return }
        writeToClipboard(text)
        flashCopied()
    }

    /// Briefly flips `justCopied` so the result toolbar can confirm the copy
    /// (⌘C is otherwise silent). Self-clearing after a short beat.
    private func flashCopied() {
        justCopied = true
        copyFlashTask?.cancel()
        copyFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
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
        streamingText = ""
        state = .visible(PanelContext(selection: sel, action: action), .generating)
        session.cancelStreaming()
        session.streamingTask = Task { @MainActor [weak self] in
            await self?.runStream(action: action, selection: sel)
        }
    }

    /// Watchdog before the first token is generous: the first generation after
    /// launch may still be loading the 7B model from a cold disk cache, which
    /// can legitimately take far longer than the inter-token stall window.
    private static let firstTokenTimeout: Duration = .seconds(90)
    private static let interTokenTimeout: Duration = .seconds(30)

    private func armWatchdog(action: Action, selection: Selection?, timeout: Duration) {
        guard let session = current else { return }
        session.watchdogTask?.cancel()
        session.watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.current?.streamingTask?.cancel()
            self.state = .visible(PanelContext(selection: selection, action: action), .error(.timeout))
        }
    }

    private func runStream(action: Action, selection: Selection?) async {
        let systemPrompt = registry.systemPrompt(for: action)
        let userPrompt = ActionPrompts.userMessage(for: action, text: selection?.text ?? "")

        armWatchdog(action: action, selection: selection, timeout: Self.firstTokenTimeout)
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
                streamingText = partial   // re-renders only StreamingResultView
                armWatchdog(action: action, selection: selection, timeout: Self.interTokenTimeout)
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
        let customPrompt: String? = action.steerText
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
            editedOutput: edited,
            threadID: nil
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

    // MARK: - Conversation

    /// Promote the showing one-shot result into a thread on the first follow-up.
    func promoteToConversation(followUp: String) {
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              case .visible(let ctx, .result(let result, _)) = state,
              let action = ctx.action, let sel = ctx.selection,
              let session = current else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Persist the thread + seed exchange if persistence is available; a nil
            // store or a failed create yields an ephemeral (unsaved, non-resumable)
            // thread rather than blocking the conversation or orphaning the result.
            let threadID = (try? await self.conversationStore?.createThread(originalSelection: sel)) ?? -1
            if threadID > 0 {
                try? await self.conversationStore?.appendExchange(
                    threadID: threadID, userText: action.pillLabel, action: action,
                    modelID: self.registry.activeModelID, assistantText: result)
            }
            // The one-shot result becomes the thread's first exchange; its pending
            // interaction is now owned by the thread (persisted above when real).
            session.pendingInteraction = nil
            guard self.current === session else { return }
            let convo = Conversation.seeded(threadID: threadID, originalSelection: sel,
                                            seedAction: action, result: result, followUp: trimmed)
            self.conversation = convo
            self.state = .visible(ctx, .conversing)
            self.runConversationTurn()
        }
    }

    /// Append a typed/chip follow-up to the live thread and stream the next reply.
    func sendFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let convo = conversation else { return }
        convo.turns.append(ConversationTurn(role: .user, text: trimmed))
        runConversationTurn()
    }

    /// Tap a refinement chip — a preset follow-up instruction.
    func tapChip(_ instruction: String) { sendFollowUp(instruction) }

    /// Retry the last (failed) conversation turn. The failed user turn is still
    /// the last turn in `convo.turns`, so this just re-streams it.
    func retryConversationTurn() {
        guard conversation != nil else { return }
        runConversationTurn()
    }

    private func runConversationTurn() {
        guard let session = current, let convo = conversation else { return }
        convo.turnError = nil   // clear any prior failed-turn error before re-streaming
        convo.streamingText = ""
        session.cancelStreaming()
        session.streamingTask = Task { @MainActor [weak self] in
            await self?.streamConversation(convo, session: session)
        }
    }

    private func streamConversation(_ convo: Conversation, session: PanelSession) async {
        let messages = [(role: "system", content: ActionPrompts.conversationSystem)] + convo.messages
        let sampling = registry.activeModel?.sampling
        var partial = ""
        do {
            for try await token in streaming.complete(messages: messages, sampling: sampling) {
                if Task.isCancelled { return }
                partial += token
                convo.streamingText = partial
            }
            if Task.isCancelled { return }
            convo.turns.append(ConversationTurn(role: .assistant, text: partial))
            convo.streamingText = ""
            // The triggering user turn is the last .user turn before this assistant turn.
            let userText = convo.turns.dropLast().last(where: { $0.role == .user })?.text ?? ""
            if convo.threadID > 0 {
                try? await conversationStore?.appendExchange(
                    threadID: convo.threadID, userText: userText, action: nil,
                    modelID: registry.activeModelID, assistantText: partial)
            }
        } catch {
            if Task.isCancelled { return }
            guard current === session else { return }
            // Keep the thread; surface the error inline (ConversationView renders it
            // with Retry). The failed user turn stays last in `turns`, so retry re-streams.
            convo.streamingText = ""
            convo.turnError = PanelError(streamingError: error)
        }
    }

    /// Accept a specific assistant turn: paste back (revise) or copy (create).
    func acceptTurn(_ turn: ConversationTurn) {
        guard turn.role == .assistant, let convo = conversation, let session = current else { return }
        switch convo.operationClass {
        case .create:
            writeToClipboard(turn.text)
            state = .hidden; conversation = nil; current = nil; hidePanelAnimated()
        case .revise:
            let capture = session.capture
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.textIO.pasteBack(result: turn.text, capture: capture)
                guard self.current === session else { return }
                if result == .skipped { self.writeToClipboard(turn.text) }
                self.state = .hidden; self.conversation = nil
                self.current = nil; self.hidePanelAnimated()
            }
        }
    }

    func openHistory() {
        guard case .visible(let ctx, _) = state else { return }
        state = .visible(ctx, .history)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recentThreads = (try? await self.conversationStore?.recentThreads(limit: 20)) ?? []
        }
    }

    func resumeThread(_ id: Int64) {
        guard let store = conversationStore else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let turns = (try? await store.loadTurns(threadID: id)) ?? []
            guard let seed = turns.first(where: { $0.role == .user })?.action else { return }
            let sel = ((try? await store.loadThread(id: id)) ?? nil) ?? Selection(text: "", sourceBundleID: nil, sourceAppName: nil)
            // Resume isn't a hotkey capture, but sendFollowUp/acceptTurn both need
            // a live session (`current`). Synthesize one with an empty capture so
            // accept on a revise thread falls back to leaving the result on the
            // clipboard (no original frontmost field to paste into).
            self.sessionCounter += 1
            let session = PanelSession(id: self.sessionCounter, capture: .empty,
                                       hotkeyTime: ContinuousClock.now)
            self.current = session
            let convo = Conversation(threadID: id, originalSelection: sel,
                                     operationClass: seed.operationClass, turns: turns)
            self.conversation = convo
            self.state = .visible(PanelContext(selection: sel, action: seed), .conversing)
        }
    }

    // MARK: - Helpers

    func currentSelection() -> Selection? {
        state.context?.selection
    }

    /// Respond needs something to reply to. False when there's no working text
    /// (no selection and an empty input field) — the row is then disabled and
    /// arrow-key nav skips it.
    var respondEnabled: Bool {
        selectionWithCurrentInput() != nil
    }

    /// Index of `.respond` in `menuItems` (the row that may be disabled).
    private var respondIndex: Int? {
        Self.menuItems.firstIndex { if case .respond = $0 { return true }; return false }
    }

    /// Advances the focused index by `step`, wrapping, skipping the Respond row
    /// when it's disabled. Falls back to the starting index if nothing else is
    /// selectable (defensive — there are always selectable rows).
    private func nextSelectableIndex(from index: Int, step: Int) -> Int {
        let n = Self.menuItems.count
        var i = index
        for _ in 0..<n {
            i = (i + step + n) % n
            if i == respondIndex && !respondEnabled { continue }
            return i
        }
        return index
    }
}
