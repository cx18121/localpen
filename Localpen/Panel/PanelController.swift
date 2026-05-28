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
    /// Claimed synchronously while a one-shot result is being promoted into a
    /// thread, so a second follow-up submitted during the async create/persist
    /// can't spawn a duplicate thread for the same result.
    @ObservationIgnored private var isPromoting = false

    /// Monotonic "intent" token for the conversation/promote/resume/history async
    /// flows. `current === session` only proves the SUMMON is unchanged — it can't
    /// see that the user navigated away (Back), accepted, or started a different
    /// transition within the same summon, because the PanelSession object survives
    /// those. Every navigation that should invalidate an in-flight conversation
    /// transition bumps this; each async transition captures it and re-checks after
    /// every await before mutating `current`/`conversation`/`state` or persisting.
    @ObservationIgnored private var convEpoch: UInt64 = 0

    /// Bumps the intent token, invalidating any in-flight conversation transition,
    /// and returns the new value for a freshly-claimed transition to capture.
    @discardableResult
    private func bumpConvEpoch() -> UInt64 {
        convEpoch &+= 1
        return convEpoch
    }

    /// Claimed synchronously by `acceptTurn` so a second `Use` tap (on another
    /// bubble) during an in-flight paste-back can't launch an overlapping,
    /// irreversible second paste. Reset on the next summon / dismiss.
    @ObservationIgnored private var isAccepting = false
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

    /// Set immediately after init via `attach(notch:)`. It can't be an init
    /// parameter: the presenter's `DynamicNotch` eagerly evaluates its content
    /// closure (which builds `PanelView(controller: self)`) during the presenter's
    /// own init, so the controller must already exist when the presenter is created.
    @ObservationIgnored private var notch: NotchPresenter?
    @ObservationIgnored private let textIO: TextIO
    @ObservationIgnored private let streaming: StreamingClient
    @ObservationIgnored private let persistence: Persistence?
    @ObservationIgnored private let registry: ModelRegistry
    @ObservationIgnored private let conversationStore: ConversationStore?
    @ObservationIgnored private weak var llamaServer: LlamaServerController?
    @ObservationIgnored private let memory: MemoryService?
    @ObservationIgnored private let contextProbe: ContextProbe
    /// Injection seam for the hotkey path's selection capture. Defaults to
    /// the real TextIO; tests override to count calls + simulate timing.
    /// The single-capture invariant is enforced through this closure being
    /// invoked exactly once per `captureAndShow` call.
    @ObservationIgnored private let captureSelection: @Sendable () async -> TextIO.Capture
    /// Injection seam for the ask streaming path. Defaults to the real
    /// StreamingClient; tests override to drive cancellation regressions.
    /// Only `startAskStream` (Task 8) uses this seam; other actions still
    /// call `streaming.complete` directly so the blast radius stays narrow.
    typealias AskStreamProvider = @Sendable (String, String, ModelDescriptor.Sampling?) -> AsyncThrowingStream<String, Error>
    @ObservationIgnored private let askStreamProvider: AskStreamProvider
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    /// Context attached to the current free-form ask session.
    var askContext: AskContext = .empty

    /// The in-flight capture→generate→accept attempt, or nil when hidden. Holds
    /// everything scoped to one summon (capture, tasks, pending result) so a
    /// "did the world move on?" check is `current === session`, not a token.
    @ObservationIgnored private var current: PanelSession?
    /// Monotonic session-ID source. Also detects supersession during the
    /// pre-capture await, before a PanelSession object exists yet.
    @ObservationIgnored private var sessionCounter: UInt64 = 0
    @ObservationIgnored private var mouseInputMonitor: Any?

    static let menuItems: [Action] = Action.fixed + [.respond(""), .custom("")]

    /// Whether accepting an assistant reply right now would paste it back into
    /// the source app (true) versus copy it to the clipboard (false). Lets the
    /// conversation bubble show the honest verb ("Replace" vs "Copy") instead
    /// of a generic "Use" that papers over real branching in `acceptTurn`.
    var pastesBackOnAccept: Bool {
        guard let session = current, let convo = conversation else { return false }
        return session.canPasteBack && convo.operationClass == .revise
    }

    @ObservationIgnored let openSettings: () -> Void

    init(textIO: TextIO,
         streaming: StreamingClient,
         persistence: Persistence?,
         registry: ModelRegistry,
         llamaServer: LlamaServerController?,
         memory: MemoryService? = nil,
         contextProbe: ContextProbe = ContextProbe(),
         captureSelection: (@Sendable () async -> TextIO.Capture)? = nil,
         askStreamProvider: AskStreamProvider? = nil,
         openSettings: @escaping () -> Void) {
        self.textIO = textIO
        self.streaming = streaming
        self.persistence = persistence
        self.conversationStore = persistence.map { ConversationStore(dbQueue: $0.dbQueue) }
        self.registry = registry
        self.llamaServer = llamaServer
        self.memory = memory
        self.contextProbe = contextProbe
        self.captureSelection = captureSelection ?? { [textIO] in
            await textIO.captureSelection()
        }
        self.askStreamProvider = askStreamProvider ?? { [streaming] sys, user, sampling in
            streaming.complete(systemPrompt: sys, userText: user, sampling: sampling)
        }
        self.openSettings = openSettings
        installMouseTracking()
    }

    /// Wire the presenter after construction (see `notch`'s doc for why it can't be
    /// an init parameter).
    func attach(notch: NotchPresenter) {
        self.notch = notch
    }

    deinit {
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
        bumpConvEpoch()   // invalidate any in-flight promote/resume/turn continuation
        isAccepting = false
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
        conversation = nil
        goIdle()
    }

    /// Return the notch to its calm resting state (compact dot). The single
    /// replacement for the old `hidePanelAnimated()` — the surface is never torn
    /// down, just collapsed, so hover/click invocation keeps working.
    private func goIdle() {
        Task { @MainActor in await notch?.idle() }
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

        case .profile:
            if code == kVK_Escape { dismissProfile(); return true }
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

        case .ask:
            // Keyboard handling for .ask is provided by the AskInput view's
            // GrowingTextEditor, not the panel keyboard router.
            return false
        }
    }

    /// Called by `NotchPresenter`'s key monitor when a text editor owns the
    /// first-responder slot. Returns `true` only for the keys that must override
    /// the editor for the current phase; `false` lets the editor handle the key
    /// normally (typing, caret motion, and `GrowingTextEditor`'s own Esc/Tab blur).
    ///
    /// This reproduces, scoped to the notch window, what `FloatingPanel.cancelOperation`
    /// did: forward Escape out of a *submit-mode* editor (compose / reply) so it backs
    /// out — but NOT out of the default input editor in `.empty`/`.captured`, where Esc
    /// must blur to the menu (handled by `GrowingTextEditor.doCommandBy`), not dismiss.
    func handleKeyWhileEditing(_ event: NSEvent) -> Bool {
        guard case .visible(_, let phase) = state else { return false }
        let code = Int(event.keyCode)
        switch phase {
        case .empty, .captured:
            // Esc dismisses in one press even while the input editor is focused —
            // there's no menu to "back" to from the menu itself, so the old
            // blur-then-dismiss double-Esc was just a papercut. Other keys (typing,
            // caret motion, Tab-to-blur) stay with the editor.
            if code == kVK_Escape { return handleKeyDown(event) }
            return false
        case .customPrompt, .conversing:
            // Submit-mode editor: Return submits via doCommandBy; only Escape needs
            // forwarding (back / dismiss), which the editor lets fall through.
            if code == kVK_Escape { return handleKeyDown(event) }
            return false
        case .result(_, let isEditing) where isEditing:
            // Inline result editing: ⌘↩ accepts, ↩ ends edit, Esc ends edit.
            if code == kVK_Escape || code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                return handleKeyDown(event)
            }
            return false
        default:
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
        bumpConvEpoch()   // Back is explicit intent to leave; cancel pending promote/resume/turn
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
        bumpConvEpoch()   // terminal: a pending promote must not fire after accept
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

        // Paste back into the source only for a revise action with a live, pasteable
        // session. A create artifact, OR a non-pasteable session (hover/click entry,
        // resumed thread — no source field), copies to the clipboard instead. Without
        // the `canPasteBack` guard, accepting a hover/click result would synthesize ⌘V
        // into whatever app is frontmost. Mirrors `acceptTurn`'s guard.
        guard case .revise = action.operationClass, session.canPasteBack else {
            writeToClipboard(text)
            state = .hidden
            current = nil
            goIdle()
            return
        }
        let capture = session.capture
        notch?.resignKey()   // let the source app receive the synthetic ⌘V
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.textIO.pasteBack(result: text, capture: capture)
            guard self.current === session else { return }
            if result == .skipped {
                self.state = .visible(PanelContext(selection: sel, action: action), .error(.pasteBackFallback))
            } else {
                self.state = .hidden
                self.current = nil
                self.goIdle()
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
            goIdle()
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

    fileprivate func captureAndShow() async {
        bumpConvEpoch()   // a new summon invalidates any lingering conversation transition
        isAccepting = false
        sessionCounter += 1
        let myID = sessionCounter
        let hotkeyTime = ContinuousClock.now
        focusedActionIndex = 1
        lastInputSource = .keyboard

        // Capture exactly ONCE through the injection seam. Single-capture
        // invariant: this same Capture is later handed to ContextProbe
        // via reusingCapture so the probe does NOT re-call TextIO.
        let capture = await captureSelection()
        guard sessionCounter == myID else { return }   // superseded during capture

        let session = PanelSession(id: myID, capture: capture, hotkeyTime: hotkeyTime)
        current = session
        inputText = capture.selection ?? ""

        let route = HotkeyRouting.route(for: capture)
        switch route {
        case .menu:
            let text = capture.selection ?? ""
            let sel = Selection(
                text: text,
                sourceBundleID: capture.sourceBundleID,
                sourceAppName: capture.sourceAppName
            )
            state = .visible(PanelContext(selection: sel), .captured)
        case .ask:
            let snap = await contextProbe.capture(reusingCapture: capture)
            // Post-probe supersession guard: a second hotkey landing during
            // the AX probe could bump sessionCounter and current. The stale
            // task must not stamp old state over new.
            guard sessionCounter == myID, current === session else { return }
            askContext = AskContext.from(snap)
            state = .visible(PanelContext(), .ask)
        }
        await notch?.expand()
        notch?.focus()
    }

    /// Hover-dwell / click invocation: open the assistant with NO capture. Routed
    /// through the same teardown as dismiss first, so an in-flight stream, a pending
    /// unaccepted result, or an outgoing hotkey capture's clipboard can't be orphaned
    /// or leak into the new session. The session is non-pasteable (no source field),
    /// so accept copies the result rather than synthesizing ⌘V into the frontmost app.
    func showFromHover() {
        // Already up (or mid-flight): ignore — don't stomp an active session.
        if state.isVisible { return }
        // Tear down any lingering session exactly like dismiss (cancel stream, flush
        // pending as rejected, restore the outgoing capture's clipboard).
        bumpConvEpoch()
        isAccepting = false
        current?.cancelStreaming()
        flushPendingAsRejected()
        if let session = current { textIO.restoreClipboard(session.capture) }

        sessionCounter += 1
        focusedActionIndex = 1
        lastInputSource = .mouse
        current = PanelSession(id: sessionCounter, capture: .empty,
                               hotkeyTime: ContinuousClock.now, canPasteBack: false)
        conversation = nil
        inputText = ""
        state = .visible(PanelContext(), .empty)
        Task { @MainActor in
            await notch?.expand()
            notch?.focus()
        }
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

    /// Tracks whether the user is driving with the mouse, so `ActionMenuView.onHover`
    /// only steals row focus during mouse use (not while arrow-key navigating). Any
    /// mouse event in our app counts as "mouse". Always-on for the app's lifetime;
    /// click-away dismissal is owned by `NotchPresenter` (it knows when expanded).
    private func installMouseTracking() {
        mouseInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastInputSource = .mouse
            }
            return event
        }
    }

    /// Routed from `NotchPresenter.onClickAway` — a click landed outside while the
    /// surface was expanded. Dismiss (which collapses back to the resting notch).
    func handleClickAway() {
        guard state.isVisible else { return }
        dismiss()
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
        let baseSystemPrompt = registry.systemPrompt(for: action)
        let systemPrompt = memory?.compose(base: baseSystemPrompt, for: action) ?? baseSystemPrompt
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

    // MARK: - Ask flow

    func removeAskAppChip() {
        askContext.appLabel = nil
    }

    func removeAskSelectionChip() {
        askContext.selection = nil
    }

    /// Entry point from AskInput's submit. Builds the Action.ask with the
    /// resolved withSelection flag from the surviving chip state and kicks
    /// off the dedicated stream path. Does NOT call `pick(_:)` — Task 9's
    /// pick(.ask) is a menu-open branch; routing submits through it would
    /// loop back to the ask screen.
    func askSubmitted(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withSel = (askContext.selection?.isEmpty == false)
        let action = Action.ask(question: trimmed, withSelection: withSel)
        let context = askContext   // snapshot at submit time
        startAskStream(action: action, context: context)
    }

    /// Streams an ask response and persists the thread via
    /// `ConversationStore.createThreadForAsk`. Mirrors the existing
    /// `runStream` watchdog + session-ownership pattern exactly.
    private func startAskStream(action: Action, context: AskContext) {
        guard case .ask(let question, _) = action else { return }
        guard let session = current else { return }

        let epoch = bumpConvEpoch()
        session.cancelStreaming()

        state = .visible(PanelContext(action: action), .generating)
        streamingText = ""

        let baseSystemPrompt = registry.systemPrompt(for: action)
        let systemPrompt = memory?.compose(base: baseSystemPrompt, for: action) ?? baseSystemPrompt
        let userMessage = ActionPrompts.askUserMessage(question: question, context: context)

        session.streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            self.armWatchdog(action: action, selection: nil,
                             timeout: PanelController.firstTokenTimeout)
            defer { self.current?.watchdogTask?.cancel() }

            var assembled = ""
            do {
                let sampling = self.registry.activeModel?.sampling
                for try await token in self.askStreamProvider(systemPrompt,
                                                              userMessage,
                                                              sampling) {
                    if Task.isCancelled { return }
                    guard self.convEpoch == epoch, self.current === session else { return }
                    assembled += token
                    self.streamingText = assembled
                    self.armWatchdog(action: action, selection: nil,
                                     timeout: PanelController.interTokenTimeout)
                }
                if Task.isCancelled { return }
            } catch {
                if Task.isCancelled { return }
                guard self.convEpoch == epoch, self.current === session else { return }
                self.state = .visible(PanelContext(action: action),
                                      .error(PanelError(streamingError: error)))
                return
            }

            guard self.convEpoch == epoch, self.current === session else { return }

            guard let store = self.conversationStore else {
                self.state = .visible(PanelContext(action: action),
                                      .result(finalResult: assembled, isEditing: false))
                return
            }
            do {
                let modelID = self.registry.activeModelID
                let (threadID, _) = try await store.createThreadForAsk(
                    question: question,
                    contextSelection: context.selection,
                    sourceApp: context.appLabel,
                    modelID: modelID,
                    assistantText: assembled
                )
                guard self.convEpoch == epoch, self.current === session else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                // Load the persisted thread and transition to .conversing.
                let sel = ((try? await store.loadThread(id: threadID)) ?? nil)
                    ?? Selection(text: "", sourceBundleID: nil, sourceAppName: nil)
                guard self.convEpoch == epoch, self.current === session else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                let turns = (try? await store.loadTurns(threadID: threadID)) ?? []
                guard self.convEpoch == epoch, self.current === session else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                let askCtx = try? await store.loadSeedAskContext(threadID: threadID)
                guard self.convEpoch == epoch, self.current === session else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                let seedAction = turns.first?.action ?? Action.ask(question: question, withSelection: withSel(context: context))
                let convo = Conversation(
                    threadID: threadID,
                    originalSelection: sel,
                    operationClass: seedAction.operationClass,
                    turns: turns,
                    seedAskContext: askCtx
                )
                self.conversation = convo
                self.state = .visible(PanelContext(), .conversing)
            } catch {
                guard self.convEpoch == epoch, self.current === session else { return }
                self.state = .visible(PanelContext(action: action),
                                      .result(finalResult: assembled, isEditing: false))
            }
        }
    }

    private func withSel(context: AskContext) -> Bool {
        context.selection?.isEmpty == false
    }

    // MARK: - Persistence

    private func buildInteraction(selection: Selection?, action: Action, output: String?, accepted: Bool, edited: String?) -> Interaction {
        let customPrompt: String? = action.steerText
        return Interaction(
            id: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
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
        guard !isPromoting,
              !trimmed.isEmpty,
              case .visible(let ctx, .result(let result, _)) = state,
              let action = ctx.action, let sel = ctx.selection,
              let session = current else { return }

        // Claim the promotion synchronously: the state stays `.result` across the
        // async create/persist below, so without this flag a second follow-up
        // submitted in that window would pass the guard and create a duplicate thread.
        isPromoting = true
        let epoch = bumpConvEpoch()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPromoting = false }
            // Atomic: the thread row and its seed exchange persist together or not
            // at all (no malformed half-written thread). nil => no store or a write
            // failure → an ephemeral (in-memory, non-resumable) thread; the one-shot
            // stays pending so teardown still records it.
            let seed = (try? await self.conversationStore?.createThreadWithSeed(
                originalSelection: sel, seedUserText: action.steerText ?? "", seedAction: action,
                modelID: self.registry.activeModelID, assistantText: result)) ?? nil
            // Re-check intent: Back / accept / dismiss / a new summon during the await
            // must not be overridden by this late completion (`current === session`
            // alone can't see those — the session object survives them). If we already
            // committed a seed, compensate by deleting it so no abandoned resumable
            // thread is left behind for a result the user terminally acted on.
            guard self.convEpoch == epoch, self.current === session else {
                if let seed { try? await self.conversationStore?.deleteThread(id: seed.threadID) }
                return
            }
            // Seed durably persisted → it now owns the record; otherwise keep the
            // pending one-shot so teardown still flushes it as rejected.
            if seed != nil { session.pendingInteraction = nil }
            let convo = Conversation.seeded(threadID: seed?.threadID ?? -1, originalSelection: sel,
                                            seedAction: action, result: result, followUp: trimmed)
            // turns = [user(seed action), assistant(result), user(followUp)]; tag the
            // seed assistant turn (index 1) with its row id so accepting it can persist.
            if let seed { convo.turns[1].interactionID = seed.seedInteractionID }
            self.conversation = convo
            self.state = .visible(ctx, .conversing)
            self.runConversationTurn()
        }
    }

    /// Append a typed/chip follow-up to the live thread and stream the next reply.
    func sendFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore submissions while a turn is in flight: appending a user turn now
        // would abandon the streaming turn and diverge the live UI from history.
        guard !trimmed.isEmpty, let convo = conversation, !convo.isStreaming else { return }
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
        convo.isStreaming = true
        let epoch = bumpConvEpoch()   // this turn is the new current intent
        session.cancelStreaming()
        session.streamingTask = Task { @MainActor [weak self] in
            await self?.streamConversation(convo, session: session, epoch: epoch)
        }
    }

    private func streamConversation(_ convo: Conversation, session: PanelSession, epoch: UInt64) async {
        let seedAction = convo.turns.first?.action
        let conversationSystem = memory?.compose(
            base: ActionPrompts.conversationSystem,
            for: .custom(""),
            seedAction: seedAction
        ) ?? ActionPrompts.conversationSystem
        let messages = [(role: "system", content: conversationSystem)] + convo.messages
        let sampling = registry.activeModel?.sampling
        var partial = ""
        do {
            for try await token in streaming.complete(messages: messages, sampling: sampling) {
                if Task.isCancelled { return }
                partial += token
                convo.streamingText = partial
            }
            if Task.isCancelled { return }
            // The user may have accepted/navigated away as the last token arrived;
            // never append or persist a reply they no longer have open.
            guard convEpoch == epoch, current === session else { return }
            convo.turns.append(ConversationTurn(role: .assistant, text: partial))
            convo.streamingText = ""
            convo.isStreaming = false
            // The triggering user turn is the last .user turn before this assistant turn.
            let userText = convo.turns.dropLast().last(where: { $0.role == .user })?.text ?? ""
            if convo.threadID > 0,
               let rowID = try? await conversationStore?.appendExchange(
                   threadID: convo.threadID, userText: userText, action: nil,
                   modelID: registry.activeModelID, assistantText: partial) {
                // Tag the just-appended assistant turn with its row id (if it's still
                // the last turn) so accepting it can mark exactly this exchange.
                if convo.turns.last?.role == .assistant {
                    convo.turns[convo.turns.count - 1].interactionID = rowID
                }
            }
        } catch {
            if Task.isCancelled { return }
            guard convEpoch == epoch, current === session else { return }
            // Keep the thread; surface the error inline (ConversationView renders it
            // with Retry). The failed user turn stays last in `turns`, so retry re-streams.
            convo.streamingText = ""
            convo.isStreaming = false
            convo.turnError = PanelError(streamingError: error)
        }
    }

    /// Accept a specific assistant turn. Paste back into the source app only for a
    /// revise thread with a live, pasteable session; otherwise (create thread, or a
    /// resumed thread with no source-app context) copy the result to the clipboard.
    func acceptTurn(_ turn: ConversationTurn) {
        // Single-flight: a second `Use` (on a different bubble) while a paste-back is
        // pending must not launch an overlapping, irreversible second paste.
        guard !isAccepting,
              turn.role == .assistant, let convo = conversation, let session = current else { return }
        isAccepting = true
        // Terminal: stop any in-flight turn and invalidate its completion so a reply
        // the user never accepted can't be appended/persisted after we close, and the
        // stale `Use` buttons on earlier bubbles can't act on a superseded session.
        bumpConvEpoch()
        session.cancelStreaming()
        // Record the accepted decision for this exchange (best-effort, like the rest
        // of persistence). Only persisted (non-ephemeral) turns carry a row id.
        if let rowID = turn.interactionID {
            Task { try? await conversationStore?.markAccepted(interactionID: rowID) }
        }
        guard session.canPasteBack, convo.operationClass == .revise else {
            // Create-class output, or a resumed thread (no live source field to
            // paste into): leave the accepted text on the clipboard.
            writeToClipboard(turn.text)
            state = .hidden; conversation = nil; current = nil; goIdle()
            return
        }
        let capture = session.capture
        notch?.resignKey()   // let the source app receive the synthetic ⌘V
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.textIO.pasteBack(result: turn.text, capture: capture)
            guard self.current === session else { return }
            if result == .skipped { self.writeToClipboard(turn.text) }
            self.state = .hidden; self.conversation = nil
            self.current = nil; self.goIdle()
        }
    }

    func openHistory() {
        guard case .visible(let ctx, _) = state else { return }
        let epoch = bumpConvEpoch()
        current?.cancelStreaming()   // entered mid-conversation: stop any in-flight turn
        state = .visible(ctx, .history)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let threads = (try? await self.conversationStore?.recentThreads(limit: 20)) ?? []
            guard self.convEpoch == epoch else { return }   // navigated away while loading
            self.recentThreads = threads
        }
    }

    func resumeThread(_ id: Int64) {
        guard let store = conversationStore else { return }
        // Preserve the outgoing (menu) session's clipboard snapshot so dismissing a
        // resumed thread still restores the user's pre-invocation clipboard — the
        // resumed session inherits it for teardown rather than a blank `.empty`.
        let priorCapture = current?.capture ?? .empty
        let epoch = bumpConvEpoch()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let turns = (try? await store.loadTurns(threadID: id)) ?? []
            let sel = ((try? await store.loadThread(id: id)) ?? nil) ?? Selection(text: "", sourceBundleID: nil, sourceAppName: nil)
            // Dismiss, Back, or a second resume during the loads above must not be
            // overridden by this late completion installing a stale session/thread.
            guard self.convEpoch == epoch else { return }
            guard let seed = turns.first(where: { $0.role == .user })?.action else { return }
            // Resume isn't a hotkey capture, but sendFollowUp/acceptTurn both need a
            // live session (`current`). Synthesize one that (a) carries the outgoing
            // clipboard snapshot for correct restore-on-dismiss, and (b) is marked
            // non-pasteable so accept copies the result rather than synthesizing ⌘V
            // into whatever app is frontmost (there's no original source field).
            self.sessionCounter += 1
            let session = PanelSession(id: self.sessionCounter, capture: priorCapture,
                                       hotkeyTime: ContinuousClock.now, canPasteBack: false)
            self.current = session
            let convo = Conversation(threadID: id, originalSelection: sel,
                                     operationClass: seed.operationClass, turns: turns)
            self.conversation = convo
            self.state = .visible(PanelContext(selection: sel, action: seed), .conversing)
        }
    }

    // MARK: - Profile (memory inspect/edit)

    // PanelController is @Observable — properties auto-observed; no @Published needed.
    var profileDraft: StyleProfile = StyleProfile()
    var profileEligibleCount: Int = 0

    func showProfile() {
        guard let memory else { return }
        profileDraft = memory.currentProfile()
        state = .visible(state.context ?? PanelContext(selection: nil), .profile)
        Task {
            if let p = persistence {
                profileEligibleCount = await p.eligibleInteractionCount(since: profileDraft.forgottenBefore)
            }
        }
    }

    func saveProfileEdits() {
        guard let memory else { return }
        var draft = profileDraft
        draft.userEdited = true
        Task { await memory.saveProfile(draft) }
    }

    func regenerateProfileNow() {
        guard let memory else { return }
        // Clear userEdited so the regen isn't suppressed; reuse the eligible count.
        Task {
            var current = memory.currentProfile()
            current.userEdited = false
            await memory.saveProfile(current)
            let count = await (persistence?.eligibleInteractionCount(since: current.forgottenBefore) ?? 0)
            memory.scheduleGeneration(eligibleAt: count)
        }
    }

    func forgetMemoryEverything() {
        guard let memory else { return }
        Task {
            await memory.forget()
            profileDraft = memory.currentProfile()
        }
    }

    func dismissProfile() {
        state = .visible(state.context ?? PanelContext(selection: nil), .empty)
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

#if DEBUG
extension PanelController {
    /// Exposed for unit tests so the hotkey path can be driven without the
    /// real notch presenter. Invokes the same private `captureAndShow` flow
    /// the hotkey would.
    @MainActor
    func captureAndShowForTesting() async {
        await captureAndShow()
    }
}
#endif
