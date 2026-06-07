import AppKit
import SwiftUI
import Observation
import Carbon.HIToolbox
import ApplicationServices
import os

@MainActor
@Observable
final class PanelController {
    var state: PanelState = .hidden
    /// The editable working text. Initialized from the captured selection on
    /// hotkey; bound to the input TextEditor in .empty/.captured states so
    /// the user can fix typos / rewrite before picking an action.
    var inputText: String = ""
    /// Whether the result panel shows the inline change-view (diff) vs the clean
    /// rewrite. Only meaningful for in-place transform results; defaults on so the
    /// user sees what changed. Toggled with ⌥D.
    var showDiff: Bool = true
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

    /// "Did the world move on while we awaited?" — the single guard every streaming and
    /// persistence continuation re-checks before touching shared surface state. `current ===
    /// session` proves the summon is unchanged; `convEpoch == epoch` proves no newer
    /// turn/thread superseded this one. Hand-copying this conjunction is how a stale stream
    /// ends up stamping over a fresh surface, so it lives in exactly one place.
    private func stillCurrent(_ epoch: UInt64, _ session: PanelSession) -> Bool {
        convEpoch == epoch && current === session
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
    /// Expanded ("focus") sizing — wider hub + taller reading surfaces (the `panelExpanded`
    /// toggle). Clamped to the screen's visibleFrame at read time so the panel can't overrun.
    static let expandedWidth: CGFloat = 560
    static let readingHeightCompact: CGFloat = 340
    static let readingHeightExpanded: CGFloat = 580

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
    /// Knowledge-context assembler (ADR 0014). nil ⇒ no brain wiring (tests, or the
    /// brain index couldn't open); the ask prompt is then byte-identical to today's.
    @ObservationIgnored private let contextEngine: ContextEngine?
    /// The brain index, for the hub's KB/People modes (search, recents). nil ⇒ those
    /// modes show empty states. Shared with the injected ContextEngine.
    @ObservationIgnored private let brainIndex: BrainIndex?
    /// The curation stash (ADR 0015): eligible Ask conversations are captured here on the
    /// hot path for the nightly dream cycle. nil / brain-off ⇒ nothing is stashed.
    @ObservationIgnored private let conversationStash: ConversationStash?
    /// The high-judgment suggestion queue (ADR 0015), surfaced in the hub's Suggestions
    /// mode for one-click apply/dismiss. nil ⇒ that mode shows an empty state.
    @ObservationIgnored private let suggestionStore: SuggestionStore?
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
    /// Injection seam for the runtime Accessibility-trust check. Defaults to the
    /// real `AXIsProcessTrusted()`; tests override to drive the revocation surface
    /// without toggling a real system permission.
    @ObservationIgnored private let isAccessibilityTrusted: @Sendable () -> Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "Latency")

    /// Context attached to the current free-form ask session.
    var askContext: AskContext = .empty

    // MARK: - Hub + Profile (ADR 0016 / memory)
    /// The hub surface's state + data loading. Views bind `controller.hub.*`; the panel
    /// transition into the hub stays here (`enterHub` sets `state`). `var` (not `let`) so the
    /// SwiftUI binding chain `$controller.hub.query` forms a writable key-path; never reassigned.
    var hub: HubModel
    /// The voice-card inspect/edit state. ProfileView binds `controller.profile.*`; the
    /// transition to the profile surface stays here (`showProfile`/`dismissProfile`).
    var profile: ProfileModel

    /// "Focus" size toggle (persisted): when on, the hub widens and the reading surfaces grow
    /// taller. Transform/editor surfaces stay compact regardless — a wide quick-action menu or
    /// a wide text column is worse, not better.
    var panelExpanded = UserDefaults.standard.bool(forKey: "panel.expanded")

    /// The panel's current width. Only the hub widens when expanded; everything else stays at
    /// the compact width (text reads better in a narrow column; the quick-action menu is small
    /// by design).
    var panelWidth: CGFloat {
        Self.width(expanded: panelExpanded, isHub: currentPhase == .hub,
                   screenWidth: NSScreen.main?.visibleFrame.width ?? 1200)
    }

    /// The max height for the scrollable reading surfaces (hub modes, conversation, history).
    var readingMaxHeight: CGFloat {
        Self.readingHeight(expanded: panelExpanded, phaseIsReading: currentPhaseIsReading,
                           screenHeight: NSScreen.main?.frame.height ?? 1000)
    }

    /// Pure sizing (testable). Only the hub widens; clamp to the screen so a wide panel can't
    /// overrun the visibleFrame.
    static func width(expanded: Bool, isHub: Bool, screenWidth: CGFloat) -> CGFloat {
        guard expanded, isHub else { return panelSize.width }
        return min(expandedWidth, screenWidth - 2 * panelEdgeMargin)
    }

    /// Reserve for the notch inset + panel chrome (mode strip / footer / hairlines / padding)
    /// when sizing the expanded reading surface against the notch window.
    static let notchChromeReserve: CGFloat = 190

    /// Pure sizing (testable). DynamicNotchKit hosts the panel in a window ~half the screen
    /// tall, so the expanded reading cap is clamped to THAT window minus chrome — never
    /// `visibleFrame` (which would let the panel grow past the window and clip the bottom). It
    /// floors at the known-safe compact height, so on a short laptop screen "expand" simply
    /// yields the width gain rather than a clipped panel; tall external displays grow both.
    static func readingHeight(expanded: Bool, phaseIsReading: Bool, screenHeight: CGFloat) -> CGFloat {
        guard expanded, phaseIsReading else { return readingHeightCompact }
        let notchWindowUsable = screenHeight / 2 - notchChromeReserve
        return max(readingHeightCompact, min(readingHeightExpanded, notchWindowUsable))
    }

    /// Flip the focus-size toggle and persist it (survives relaunch).
    func togglePanelExpanded() {
        panelExpanded.toggle()
        UserDefaults.standard.set(panelExpanded, forKey: "panel.expanded")
    }

    private var currentPhase: PanelState.Phase? {
        if case .visible(_, let phase) = state { return phase }
        return nil
    }
    private var currentPhaseIsReading: Bool {
        switch currentPhase {
        case .hub, .conversing, .history: return true
        default: return false
        }
    }

    /// The AskContext snapshot of the most recent `startAskStream`, kept so a
    /// retry from the error banner can re-run the ask through `startAskStream`
    /// (preserving the context block + prompt shape) instead of `startGeneration`,
    /// which would rebuild the prompt via `userMessage(for:.ask)` and lose it.
    @ObservationIgnored private var pendingAskContext: AskContext = .empty

    /// The frontmost app's pid at summon (ADR 0020). Held so a deferred Files capture
    /// can read the document that was open when you summoned — by add-time Localpen is
    /// frontmost, so this is the only way to reach the right window. 0 = unknown.
    @ObservationIgnored private var summonPID: pid_t = 0

    /// In-flight `addAskSource` captures for the current session (ADR 0020 opt-in tray).
    /// `askSubmitted` awaits them so adding a source then immediately pressing return
    /// can't stream the ask before that source's capture lands. Reset per summon.
    @ObservationIgnored private var sourceAddTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sourceAddSession: UInt64 = 0   // 0 = none; real sessions are ≥ 1

    // MARK: Mail picker (ADR 0020 — mail is retrieval, not a recency dump). Opened from the
    // "+ Mail" tray: recent inbox (last day) by default, search by sender/subject, the user
    // checks emails to attach as full-body ask context. State is per-ask (reset on summon).
    var mailPickerActive = false
    var mailPickerQuery = ""
    private(set) var mailPickerResults: [MailMessage] = []
    private(set) var mailPickerSelected: [Int64: MailMessage] = [:]   // id → checked message
    private(set) var mailPickerBodies: [Int64: String] = [:]          // expanded-row preview bodies
    private(set) var mailPickerSnippets: [Int64: String] = [:]        // why a search row matched
    private(set) var mailPickerLoading = false
    private(set) var mailIndexing = false                            // FTS body index building
    private(set) var savedMailIDs: Set<Int64> = []                    // promoted to cxkb (dedup)
    var mailSaveStatus: String?                                      // transient "Saved"/error
    @ObservationIgnored private let mailReader: any MailStoreReading
    @ObservationIgnored private var mailSearchTask: Task<Void, Never>?
    /// FTS5 index over recent inbox bodies (ADR 0019 follow-up) — built lazily so search
    /// finds body-only matches the sender/subject `LIKE` can't. nil if it can't open.
    @ObservationIgnored private let mailSearchIndex = MailSearchIndex()
    @ObservationIgnored private var mailIndexTask: Task<Void, Never>?

    /// The in-flight capture→generate→accept attempt, or nil when hidden. Holds
    /// everything scoped to one summon (capture, tasks, pending result) so a
    /// "did the world move on?" check is `current === session`, not a token.
    @ObservationIgnored private var current: PanelSession?
    /// Monotonic session-ID source. Also detects supersession during the
    /// pre-capture await, before a PanelSession object exists yet.
    @ObservationIgnored private var sessionCounter: UInt64 = 0
    /// Set synchronously when a hotkey capture is launched and cleared when it
    /// returns. captureAndShow only sets `state = .visible` AFTER the ~90ms ⌘C
    /// settle, so a second hotkey within that window would otherwise pass the
    /// `.isVisible` check and fire a second synthetic ⌘C — corrupting the saved
    /// clipboard snapshot. This collapses a rapid double-tap to one capture.
    @ObservationIgnored private var captureInFlight = false
    @ObservationIgnored private var mouseInputMonitor: Any?
    /// The auto-collapse timer for the `.warming` beat, cancelled if the user
    /// dismisses it first (Esc/click-away) so it can't goIdle a panel the user
    /// has since reopened.
    @ObservationIgnored private var warmingTask: Task<Void, Never>?

    static let menuItems: [Action] = Action.fixed + [
        .respond(""),
        .ask(question: "", withSelection: false),   // placeholder; selection resolved when picked
        .custom("")
    ]

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
         mailReader: any MailStoreReading = SystemMailStoreReader(),
         contextEngine: ContextEngine? = nil,
         brainIndex: BrainIndex? = nil,
         conversationStash: ConversationStash? = nil,
         suggestionStore: SuggestionStore? = nil,
         captureSelection: (@Sendable () async -> TextIO.Capture)? = nil,
         askStreamProvider: AskStreamProvider? = nil,
         isAccessibilityTrusted: (@Sendable () -> Bool)? = nil,
         openSettings: @escaping () -> Void) {
        self.textIO = textIO
        self.streaming = streaming
        self.persistence = persistence
        self.conversationStore = persistence.map { ConversationStore(dbQueue: $0.dbQueue) }
        self.registry = registry
        self.llamaServer = llamaServer
        self.memory = memory
        self.contextProbe = contextProbe
        self.mailReader = mailReader
        self.contextEngine = contextEngine
        self.brainIndex = brainIndex
        self.conversationStash = conversationStash
        self.suggestionStore = suggestionStore
        self.captureSelection = captureSelection ?? { [textIO] in
            await textIO.captureSelection()
        }
        self.askStreamProvider = askStreamProvider ?? { [streaming] sys, user, sampling in
            streaming.complete(systemPrompt: sys, userText: user, sampling: sampling,
                               onTimings: { InferenceMetrics.shared.record(.ask, $0) })
        }
        self.isAccessibilityTrusted = isAccessibilityTrusted ?? { AXIsProcessTrusted() }
        self.openSettings = openSettings
        self.hub = HubModel(brainIndex: brainIndex, suggestionStore: suggestionStore)
        self.profile = ProfileModel(memory: memory, persistence: persistence)
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
        if captureInFlight { return }   // a capture is mid-settle; ignore the second press
        captureInFlight = true
        Task { await captureAndShow(); captureInFlight = false }
    }

    func dismiss() {
        bumpConvEpoch()   // invalidate any in-flight promote/resume/turn continuation
        isAccepting = false
        warmingTask?.cancel()   // kill any pending warming auto-collapse
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

        case .warming:
            // Inert beat: Esc dismisses (same as the auto-collapse), nothing else.
            if code == kVK_Escape { dismiss(); return true }
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
                case kVK_ANSI_D where mods.contains(.option):
                    toggleDiffView()   // ⌥D flips changes/clean (no-op visually for create actions)
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

        case .hub:
            switch code {
            case kVK_Escape:
                // Clear a non-empty KB query first; otherwise dismiss.
                if !hub.query.isEmpty { hub.query = ""; hub.searchNotes(); return true }
                dismiss(); return true
            case kVK_Tab:
                let modes = HubMode.allCases
                if let i = modes.firstIndex(of: hub.mode) {
                    let next = shift ? (i - 1 + modes.count) % modes.count : (i + 1) % modes.count
                    hub.setMode(modes[next])
                }
                return true
            default:
                return false
            }
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
        case .hub:
            // In an editor mode (Ask/Capture), forward Esc (clear query / dismiss) AND Tab
            // (switch mode — the hub's global affordance) to the hub router. Without the Tab
            // forward the text view eats it as an indent, so ⇥ silently stops switching modes
            // whenever the focused mode has an input field. The editor keeps all other keys.
            if code == kVK_Escape || code == kVK_Tab { return handleKeyDown(event) }
            return false
        default:
            return false
        }
    }

    // MARK: - State transitions

    func pick(_ action: Action) {
        if case .respond = action, !respondEnabled { return }
        switch action {
        case .ask:
            // Menu-open only. Submission goes through askSubmitted →
            // startAskStream directly (Codex plan review HIGH 2: routing
            // submit back through pick(.ask) would loop into menu-open
            // and never reach the stream path).
            if case .visible(let ctx, _) = state, let sel = ctx.selection {
                askContext = AskContext(selection: sel.text)
            } else {
                askContext = .empty
            }
            beginAskContext()   // opt-in tray; the summon pid carries over from the original capture (ADR 0020)
            state = .visible(PanelContext(), .ask)
            return
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
        // Single-flight, mirroring acceptTurn/copyTurn: a fast double Return (or
        // Enter key-repeat) during the ~850ms paste-back window must not launch a
        // second synthetic ⌘V that re-clobbers the clipboard. isAccepting resets on
        // every summon/dismiss path, and the .pasteBackFallback branch below.
        guard !isAccepting,
              case .visible(let ctx, .result(let text, _)) = state,
              let action = ctx.action,
              let session = current else { return }
        isAccepting = true
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

    func toggleDiffView() {
        // ⌥D only means something for an in-place transform result with an original to
        // compare. Ignoring it elsewhere keeps a create result (or empty selection) from
        // silently flipping the default that the *next* revise result will inherit.
        guard case .visible(let ctx, .result) = state,
              ctx.action?.operationClass == .revise, ctx.selection != nil else { return }
        showDiff.toggle()
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
                    self?.retryGeneration(action: action, selection: ctx.selection)
                } else {
                    self?.backToMenu()
                }
            }
        case .timeout, .network:
            if let action = ctx.action {
                retryGeneration(action: action, selection: ctx.selection)
            } else {
                backToMenu()
            }
        case .pasteBackFallback:
            current?.cancelStreaming()
            flushPendingAsRejected()
            isAccepting = false   // acceptResult/acceptTurn set this; clear it on this terminal path
            state = .hidden
            current = nil
            goIdle()
        case .diskFull:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            backToMenu()
        case .hotkeyConflict:
            openSettings()
            backToMenu()
        case .accessibilityLost:
            // Deep-link straight to the Accessibility privacy pane so the fix is
            // one click away, then collapse — re-granting trust happens in System
            // Settings, and the next hotkey press will capture normally.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            dismiss()
        }
    }

    private func restartServer() async {
        guard let server = llamaServer, let descriptor = registry.activeModel else { return }
        server.stopChat()   // recover the chat server without dropping the embedding server
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
        // Record the frontmost app NOW (the user's app, before the notch shows) so a
        // later Files add can read its open document (ADR 0020).
        summonPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        // Accessibility can be revoked AFTER first-run (System Settings → Privacy).
        // Without trust, the synthetic ⌘C capture and ⌘V paste-back silently no-op,
        // so the panel would open over a stale/empty selection and "do nothing".
        // Surface it loudly instead: set up a non-pasteable session (so dismiss
        // tears down cleanly) and present the error, skipping capture entirely.
        if !isAccessibilityTrusted() {
            let session = PanelSession(id: myID, capture: .empty,
                                       hotkeyTime: hotkeyTime, canPasteBack: false)
            current = session
            conversation = nil
            inputText = ""
            state = .visible(PanelContext(), .error(.accessibilityLost))
            await notch?.expand()
            notch?.focus()
            return
        }

        // Capture exactly ONCE through the injection seam. Single-capture
        // invariant: this same Capture is later handed to ContextProbe
        // via reusingCapture so the probe does NOT re-call TextIO.
        let capture = await captureSelection()
        // Superseded during the ⌘C settle: no session will own this capture, so
        // restore the clipboard it overwrote before bailing (else the selection
        // leaks onto the user's clipboard).
        guard sessionCounter == myID else { textIO.restoreClipboard(capture); return }

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
            // task must not stamp old state over new — and must restore the
            // clipboard it captured, since no surviving session owns it.
            guard sessionCounter == myID, current === session else {
                textIO.restoreClipboard(capture); return
            }
            beginAskContext()
            askContext = AskContext(selection: snap.selection)   // opt-in: only the operand attaches (ADR 0020)
            enterHub()   // no-selection hotkey lands on the hub home (ADR 0016), opened on Ask
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
        // A hotkey capture is mid-settle (state not yet visible): don't supersede
        // it. Opening a hover session here would orphan the in-flight capture's
        // clipboard snapshot (no session left to restore it).
        if captureInFlight { return }
        // Tear down any lingering session exactly like dismiss (cancel stream, flush
        // pending as rejected, restore the outgoing capture's clipboard).
        bumpConvEpoch()
        isAccepting = false
        current?.cancelStreaming()
        flushPendingAsRejected()
        if let session = current { textIO.restoreClipboard(session.capture) }

        // Grab the frontmost app's pid BEFORE we touch the notch (hover is non-activating,
        // so this is still the user's app) so a later Files add can read its document.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        sessionCounter += 1
        focusedActionIndex = 1
        lastInputSource = .mouse
        current = PanelSession(id: sessionCounter, capture: .empty,
                               hotkeyTime: ContinuousClock.now, canPasteBack: false)
        conversation = nil
        inputText = ""
        // Land on free-form Ask (the headline pivot), not the transform menu, so the
        // most ambient entry point reaches the assistant. No selection (hover is a
        // no-capture entry — never synthesize ⌘C here); ambient context is opt-in via the
        // add-context tray (ADR 0020). Submitting is Copy-only (non-pasteable session).
        summonPID = frontmostPID
        beginAskContext()
        askContext = AskContext(selection: nil)   // opt-in: nothing ambient auto-attaches (ADR 0020)
        enterHub()                // hover lands on the hub home (ADR 0016), opened on Ask
        Task { @MainActor in
            await notch?.expand()
            notch?.focus()
        }
    }

    /// The hotkey fired before the llama-server finished loading. Rather than a
    /// silent beep (which reads as a broken hotkey on every cold launch), open
    /// a quiet "setting up the model" beat so the press visibly does something.
    /// Sets up a minimal non-pasteable session (mirroring `showFromHover`) so a
    /// later dismiss tears down cleanly, then auto-collapses after a short beat —
    /// Esc / click-away dismiss it normally before then.
    func showWarmingUp() {
        // Already up (or mid-capture): don't stomp a real session with a warming beat.
        if state.isVisible { return }
        if captureInFlight { return }
        bumpConvEpoch()
        isAccepting = false
        current?.cancelStreaming()
        flushPendingAsRejected()
        if let session = current { textIO.restoreClipboard(session.capture) }

        sessionCounter += 1
        focusedActionIndex = 1
        lastInputSource = .keyboard
        current = PanelSession(id: sessionCounter, capture: .empty,
                               hotkeyTime: ContinuousClock.now, canPasteBack: false)
        conversation = nil
        inputText = ""
        state = .visible(PanelContext(), .warming)
        Task { @MainActor in
            await notch?.expand()
            notch?.focus()
        }

        // Auto-collapse if the user hasn't dismissed it: a quiet beat, not a
        // sticky panel. Only acts while still showing `.warming` (a real summon
        // landing in the meantime would have replaced the phase).
        warmingTask?.cancel()
        warmingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self else { return }
            if case .visible(_, .warming) = self.state { self.dismiss() }
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

    /// Re-dispatch a retry to the right streaming path. Ask must go back through
    /// `startAskStream` (rebuilds via `askUserMessage` + streams into the
    /// conversation surface); every other action uses `startGeneration`. Without
    /// this, a retried ask would lose its context block and flash the `.generating`
    /// view, since `startGeneration` builds the prompt with `userMessage(for:.ask)`.
    private func retryGeneration(action: Action, selection: Selection?) {
        if case .ask = action {
            startAskStream(action: action, context: pendingAskContext)
        } else {
            startGeneration(action: action, selection: selection)
        }
    }

    private func startGeneration(action: Action, selection explicitSel: Selection? = nil) {
        guard let session = current else { return }
        let sel = explicitSel ?? currentSelection()
        streamingText = ""
        showDiff = true   // every new rewrite defaults to showing changes (don't carry over a prior ⌥D-to-clean)
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

    /// Arm a stall watchdog on `session`: after `timeout` with no disarm, cancel the stream
    /// and run `onTimeout` — but only if we still own the exact session+epoch we armed for (a
    /// navigation, dismiss, or new turn during the wait must not let a stale watchdog cancel a
    /// live stream or stamp an error over a fresh surface). How the timeout *surfaces* is the
    /// only thing that varies between callers, so it's the one injected parameter.
    private func armWatchdog(session: PanelSession, epoch: UInt64, timeout: Duration,
                             onTimeout: @escaping () -> Void) {
        session.watchdogTask?.cancel()
        session.watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.stillCurrent(epoch, session) else { return }
            self.current?.streamingTask?.cancel()
            onTimeout()
        }
    }

    /// One-shot path: a stall surfaces as the global `.error(.timeout)` banner.
    private func armWatchdog(action: Action, selection: Selection?, timeout: Duration) {
        guard let session = current else { return }
        armWatchdog(session: session, epoch: convEpoch, timeout: timeout) { [weak self] in
            self?.state = .visible(PanelContext(selection: selection, action: action), .error(.timeout))
        }
    }

    /// Conversation/ask follow-up turns: a stall surfaces INLINE via `convo.turnError`, so
    /// ConversationView's TurnErrorRow + retry re-runs the turn rather than routing through
    /// `startGeneration`. Closes the ADR 0010 deferral (no watchdog on conversation turns).
    private func armConversationWatchdog(_ convo: Conversation, session: PanelSession,
                                         epoch: UInt64, timeout: Duration) {
        armWatchdog(session: session, epoch: epoch, timeout: timeout) {
            convo.streamingText = ""
            convo.isStreaming = false
            convo.turnError = .timeout
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
            for try await token in streaming.complete(
                systemPrompt: systemPrompt, userText: userPrompt, sampling: sampling,
                onTimings: { InferenceMetrics.shared.record(.rewrite, $0) }) {
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

    // MARK: - Hub (ADR 0016)

    /// Enter the hub as the no-selection home. `HubModel` restores the last-used mode + loads
    /// its data; this method owns only the panel transition. Callers set `askContext` (for the
    /// Ask mode's chips) before calling.
    func enterHub() {
        hub.enter()
        state = .visible(PanelContext(), .hub)
    }

    /// Open an answer's source page (provenance chip, ADR 0014) in Obsidian. Lives here (not on
    /// HubModel) because it serves the ask/conversation surface, not the hub.
    func openProvenanceSource(_ source: ContextBundle.Provenance) {
        NSWorkspace.shared.open(URL(fileURLWithPath: source.path))
    }

    // MARK: - Ask flow

    /// Remove one ambient context source's chip (ADR 0019) — app, calendar, files, …
    func removeAskSource(_ kind: ContextKind) {
        askContext.removeSource(kind)
        if kind == .mail { mailPickerSelected = [:]; mailPickerBodies = [:] }   // start fresh next time
    }

    func removeAskSelectionChip() {
        askContext.selection = nil
    }

    /// Reset the opt-in context state for a fresh ask (ADR 0020): drop any pending adds
    /// and the mail-picker selection from the prior ask. The summon pid is recorded
    /// separately at each summon point (it must be read while the user's app is still
    /// frontmost). Called before the ask shows.
    private func beginAskContext() {
        sourceAddTasks = []
        sourceAddSession = sessionCounter
        mailPickerActive = false
        mailPickerQuery = ""
        mailPickerResults = []
        mailPickerSelected = [:]
        mailPickerBodies = [:]
        mailPickerSnippets = [:]
        savedMailIDs = []
        mailSaveStatus = nil
    }

    /// The capture-time sources the user can ADD to this ask (ADR 0020): enabled in
    /// Settings and not already attached. Files needs a known summon app to read from.
    /// The chip rail renders these as an "add context" tray.
    var availableAskSources: [ContextKind] {
        let attached = Set(askContext.sources.map(\.kind))
        var kinds: [ContextKind] = []
        if CalendarAccess.isActive { kinds.append(.calendar) }
        if FilesAccess.isActive, summonPID > 0 { kinds.append(.files) }
        if ScreenAccess.isActive, summonPID > 0 { kinds.append(.screen) }
        if MailAccess.isActive { kinds.append(.mail) }
        return kinds.filter { !attached.contains($0) }
    }

    /// Add one capture-time source to this ask, captured lazily NOW (ADR 0020) — so an
    /// ask that adds nothing reads nothing. Files reads the held summon app's document;
    /// calendar/mail read their feed/store fresh. The session guard drops a late capture
    /// whose ask has been superseded; nil (nothing to add / unreadable) is a no-op.
    func addAskSource(_ kind: ContextKind) {
        // Mail is retrieval, not a recency dump (ADR 0020): "+ Mail" opens the picker
        // (recent + search + see/check), which attaches on confirm. Other sources capture
        // lazily and attach directly.
        if kind == .mail { openMailPicker(); return }
        guard !askContext.sources.contains(where: { $0.kind == kind }) else { return }
        let myCounter = sessionCounter
        sourceAddSession = myCounter
        let pid = summonPID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let item: ContextItem?
            switch kind {
            case .calendar:
                item = (await self.contextProbe.readCalendarOffMain()).map(ContextItem.calendar)
            case .files:
                item = await FilesContextSource(isEnabled: { true }, pid: { pid }).capture()
            case .screen:
                item = await ScreenCapture.captureWindowText(pid: pid, charCap: ScreenAccess.bodyCharCap)
                    .map { ContextItem.screen(app: $0.appName, text: $0.text) }
            default:
                item = nil
            }
            guard self.sessionCounter == myCounter, let item else { return }
            self.askContext.setSource(item.kind, item)
        }
        sourceAddTasks.append(task)
    }

    // MARK: - Mail picker (ADR 0020)

    /// Open the mail picker. Tapping "+ Mail" or the attached mail chip both land here;
    /// the prior selection (if any) is preserved so reopening edits rather than restarts.
    func openMailPicker() {
        guard MailAccess.isActive else { return }
        mailPickerActive = true
        savedMailIDs = mailSearchIndex?.savedIDs() ?? []   // reflect prior saves across sessions
        mailSaveStatus = nil
        refreshMailSearchIndex()        // build/extend the body index in the background
        loadMailList(mailPickerQuery)
    }

    /// Promote an email into the cxkb inbox (raw/inbox/) so the dream cycle can fold it into
    /// people/topics. Deduped: the same email can't be saved twice (`savedMailIDs`, persisted
    /// in the index DB). Optimistically marks saved to disable the button + block double-taps;
    /// rolls back on failure with the (now readable) write error.
    func saveEmailToCxkb(_ msg: MailMessage) {
        guard !savedMailIDs.contains(msg.id) else { return }
        savedMailIDs.insert(msg.id)
        mailSaveStatus = nil
        let reader = mailReader
        let index = mailSearchIndex
        let cap = MailAccess.savedNoteCharCap   // archival cap — keep more than a prompt slice
        let id = msg.id
        Task { @MainActor [weak self] in
            let body: String
            if let b = msg.body, !b.isEmpty {
                body = b
            } else {
                body = await Task.detached(priority: .utility) { reader.body(forID: id, charCap: cap) }.value
            }
            let note = MailContextFormatter.cxkbNote(msg, body: body)
            let error = await Task.detached(priority: .utility) { () -> String? in
                do {
                    _ = try VaultWriter(vaultRoot: BrainAccess.vaultRoot)
                        .applyApproved(.captureToInbox(text: note), nowMillis: Int64(Date().timeIntervalSince1970 * 1000))
                    return nil
                } catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            if let error {
                self.savedMailIDs.remove(id)
                self.mailSaveStatus = "Couldn't save: \(error)"
            } else {
                index?.markSaved(id)
                self.mailSaveStatus = "Saved to cxkb"
            }
        }
    }

    /// Build (or incrementally extend) the recent-inbox FTS index off-main. Reads bodies
    /// only for emails not already indexed, in one filesystem pass. The ~last-90-day window
    /// is the search scope; sender/subject search works immediately while this fills in.
    private func refreshMailSearchIndex() {
        guard let index = mailSearchIndex, mailIndexTask == nil else { return }
        let reader = mailReader
        let sinceEpoch = Date().timeIntervalSince1970 - Double(MailAccess.searchWindowDays) * 86400
        mailIndexing = true
        mailIndexTask = Task.detached(priority: .utility) { [weak self] in
            let candidates = reader.recentInbox(sinceEpoch: sinceEpoch, limit: MailAccess.searchIndexCap)
            let currentIDs = Set(candidates.map(\.id))
            let already = index.indexedIDs()
            // Prune mail that's left the inbox window (archived/deleted/aged out) so stale
            // hits don't show, then index any new mail since last open.
            index.remove(ids: Array(already.subtracting(currentIDs)))
            let fresh = candidates.filter { !already.contains($0.id) }
            if !fresh.isEmpty {
                let bodies = reader.bodies(forIDs: fresh.map(\.id), charCap: MailAccess.indexBodyCharCap)
                index.insert(fresh.map {
                    MailMessage(id: $0.id, sender: $0.sender, subject: $0.subject, date: $0.date, body: bodies[$0.id])
                })
            }
            // Clear the gate so a later open does a cheap incremental pass (new mail only),
            // and upgrade an active sender/subject fallback search to full-text now.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.mailIndexing = false
                self.mailIndexTask = nil
                if self.mailPickerActive,
                   !self.mailPickerQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.loadMailList(self.mailPickerQuery)
                }
            }
        }
    }

    /// Re-run the list for the current query: empty ⇒ recent inbox (last day window),
    /// non-empty ⇒ sender/subject search. Off-main; the latest query wins.
    func mailQueryChanged(_ query: String) {
        mailPickerQuery = query
        loadMailList(query)
    }

    private func loadMailList(_ query: String) {
        mailPickerLoading = true
        let reader = mailReader
        let index = mailSearchIndex
        let limit = MailAccess.listLimit
        let sinceEpoch = Date().timeIntervalSince1970 - Double(MailAccess.recentWindowHours) * 3600
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        mailSearchTask?.cancel()
        mailSearchTask = Task { @MainActor [weak self] in
            let (results, snippets) = await Task.detached(priority: .userInitiated) {
                () -> ([MailMessage], [Int64: String]) in
                if q.isEmpty {
                    // Empty query = the recent view (always current, straight from the store).
                    return (reader.recentInbox(sinceEpoch: sinceEpoch, limit: limit), [:])
                }
                // Full-text body search once the index has content; until then fall back to
                // sender/subject so search is never dead while the index builds.
                if let index, index.count > 0 {
                    let hits = index.search(q, limit: limit)
                    return (hits.map(\.message), Dictionary(hits.map { ($0.message.id, $0.snippet) }, uniquingKeysWith: { a, _ in a }))
                }
                return (reader.search(q, limit: limit), [:])
            }.value
            guard let self, !Task.isCancelled else { return }
            self.mailPickerResults = results
            self.mailPickerSnippets = snippets
            self.mailPickerLoading = false
        }
    }

    /// Toggle whether a listed email is attached.
    func toggleMailSelection(_ msg: MailMessage) {
        if mailPickerSelected[msg.id] != nil { mailPickerSelected[msg.id] = nil }
        else { mailPickerSelected[msg.id] = msg }
    }

    func isMailSelected(_ id: Int64) -> Bool { mailPickerSelected[id] != nil }

    /// Lazily load one email's body for an expanded preview row.
    func expandMailPreview(_ msg: MailMessage) {
        guard mailPickerBodies[msg.id] == nil else { return }
        let reader = mailReader
        let cap = MailAccess.bodyCharCap
        let id = msg.id
        Task { @MainActor [weak self] in
            let body = await Task.detached(priority: .utility) { reader.body(forID: id, charCap: cap) }.value
            self?.mailPickerBodies[id] = body
        }
    }

    func cancelMailPicker() {
        mailPickerActive = false
        mailSearchTask?.cancel()
    }

    /// Attach the checked emails (full bodies, fetched now) as the mail context, or clear
    /// it if none are checked. Runs as a tracked add so a fast submit awaits the bodies.
    func confirmMailPicker() {
        mailPickerActive = false
        mailSearchTask?.cancel()
        let selected = Array(mailPickerSelected.values).sorted { $0.date > $1.date }
        guard !selected.isEmpty else { askContext.removeSource(.mail); return }
        let reader = mailReader
        let cap = MailAccess.bodyCharCap
        let myCounter = sessionCounter
        sourceAddSession = myCounter
        let task = Task { @MainActor [weak self] in
            // Fetch every missing body in ONE filesystem pass (the store has no computable
            // path, so each individual `body` call rescans ~20k files) — `bodies(forIDs:)`
            // exists precisely so attaching N emails isn't N full-tree scans.
            let missingIDs = selected.filter { $0.body == nil }.map(\.id)
            let fetched = missingIDs.isEmpty ? [:] : await Task.detached(priority: .utility) {
                reader.bodies(forIDs: missingIDs, charCap: cap)
            }.value
            let withBodies = selected.map { m -> MailMessage in
                guard m.body == nil else { return m }
                var m = m; m.body = fetched[m.id] ?? ""; return m
            }
            guard let self, self.sessionCounter == myCounter else { return }
            self.askContext.setSource(.mail, .mail(count: withBodies.count,
                                                   body: MailContextFormatter.block(withBodies)))
        }
        sourceAddTasks.append(task)
    }

    /// Entry point from AskInput's submit. Builds the Action.ask with the
    /// resolved withSelection flag from the surviving chip state and kicks
    /// off the dedicated stream path. Does NOT call `pick(_:)` — Task 9's
    /// pick(.ask) is a menu-open branch; routing submits through it would
    /// loop back to the ask screen.
    func askSubmitted(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The user may have just tapped "add context" and its lazy capture is still in
        // flight (ADR 0020). If so — and the adds belong to THIS session — await them
        // before snapshotting, so a fast submit doesn't stream/persist the ask without
        // the source the user explicitly added. With no pending adds, submit is synchronous.
        let pendingAdds = sourceAddTasks
        if sourceAddSession == sessionCounter, !pendingAdds.isEmpty {
            let submitEpoch = convEpoch
            Task { @MainActor [weak self] in
                for task in pendingAdds { await task.value }
                // Re-check the intent token after the await. convEpoch is bumped by
                // EVERY way the user can move on while the read finishes — dismiss,
                // reopen (new session), History, Back-to-menu. Guarding on it (not
                // just sessionCounter, which History/Back leave intact) drops the
                // stale submit so the old question can't stream over the new surface
                // (Codex review HIGH + its same-session-navigation follow-up).
                guard let self, self.convEpoch == submitEpoch else { return }
                self.finishAskSubmit(trimmed)
            }
        } else {
            finishAskSubmit(trimmed)
        }
    }

    private func finishAskSubmit(_ question: String) {
        let action = Action.ask(question: question, withSelection: askContext.hasSelection)
        let context = askContext   // snapshot after any pending calendar read landed
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
        pendingAskContext = context   // so a retry-from-error can re-run the ask, not startGeneration

        // Stream the answer straight into the conversation surface so there's no
        // .generating → .conversing layout jump: the user's question shows as the
        // seed bubble and the reply streams into a live assistant bubble in place.
        // threadID 0 = not yet persisted; we persist on completion, so a mid-stream
        // dismiss fails the epoch guard before createThreadForAsk and leaves nothing
        // in Recent (see test_dismissDuringAskStream_doesNotPersistThread).
        let liveConvo = Conversation(
            threadID: 0,
            originalSelection: Selection(text: question,
                                         sourceBundleID: session.capture.sourceBundleID,
                                         sourceAppName: session.capture.sourceAppName),
            operationClass: action.operationClass,
            turns: [ConversationTurn(role: .user, text: action.pillLabel, action: action)],
            seedAskContext: context
        )
        liveConvo.isStreaming = true
        conversation = liveConvo
        state = .visible(PanelContext(), .conversing)

        let baseSystemPrompt = registry.systemPrompt(for: action)
        let systemPrompt = memory?.compose(base: baseSystemPrompt, for: action) ?? baseSystemPrompt

        session.streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Assemble the knowledge bundle now — relevance is query-dependent, so it
            // runs at stream time (the question exists here), not at capture like calendar.
            // Off/empty ⇒ ctx.knowledge stays nil ⇒ byte-identical prompt + nothing persisted.
            var ctx = context
            var provenance: [ContextBundle.Provenance] = []
            if let engine = self.contextEngine {
                let kb = await engine.bundle(for: question)
                if !kb.text.isEmpty { ctx.knowledge = kb.text }
                provenance = kb.sources
            }
            liveConvo.provenance = provenance   // show source chips while the answer streams
            guard self.stillCurrent(epoch, session) else { return }
            let userMessage = ActionPrompts.askUserMessage(question: question, context: ctx)

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
                    guard self.stillCurrent(epoch, session) else { return }
                    assembled += token
                    liveConvo.streamingText = assembled
                    self.armWatchdog(action: action, selection: nil,
                                     timeout: PanelController.interTokenTimeout)
                }
                if Task.isCancelled { return }
            } catch {
                if Task.isCancelled { return }
                guard self.stillCurrent(epoch, session) else { return }
                self.state = .visible(PanelContext(action: action),
                                      .error(PanelError(streamingError: error)))
                return
            }

            guard self.stillCurrent(epoch, session) else { return }
            // No more tokens are coming — disarm the inter-token watchdog before the
            // DB awaits below, so a slow disk can't let it fire and stamp
            // .error(.timeout) over a completed answer mid-persist.
            self.current?.watchdogTask?.cancel()

            guard let store = self.conversationStore else {
                // No persistence available: finalize the answer in the conversation
                // surface anyway (no Recent entry, but the answer + accept show).
                liveConvo.turns.append(ConversationTurn(role: .assistant, text: assembled))
                liveConvo.streamingText = ""
                liveConvo.isStreaming = false
                return
            }
            do {
                let modelID = self.registry.activeModelID
                let (threadID, _) = try await store.createThreadForAsk(
                    question: question,
                    contextSelection: context.selection,
                    sourceApp: context.appLabel,
                    // App replays from source_app above; persist the remaining ambient
                    // sources (calendar, files, …) as the v8 context_sources JSON (ADR 0019).
                    contextSources: context.sources.filter { $0.kind != .app },
                    contextKnowledge: ctx.knowledge,
                    contextProvenance: ContextBundle.Provenance.encode(provenance),
                    modelID: modelID,
                    assistantText: assembled
                )
                guard self.stillCurrent(epoch, session) else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                // Load the persisted thread and transition to .conversing.
                let sel = ((try? await store.loadThread(id: threadID)) ?? nil)
                    ?? Selection(text: "", sourceBundleID: nil, sourceAppName: nil)
                guard self.stillCurrent(epoch, session) else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                let turns = (try? await store.loadTurns(threadID: threadID)) ?? []
                guard self.stillCurrent(epoch, session) else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                // Reload must yield a usable thread (seed + assistant). If it
                // didn't — load failed or returned no rows — don't install a
                // blank conversation that drops the streamed answer; finalize the
                // in-memory liveConvo (which holds the completed answer) instead.
                guard turns.contains(where: { $0.role == .assistant }) else {
                    liveConvo.turns.append(ConversationTurn(role: .assistant, text: assembled))
                    liveConvo.streamingText = ""
                    liveConvo.isStreaming = false
                    return
                }
                let askCtx = try? await store.loadSeedAskContext(threadID: threadID)
                guard self.stillCurrent(epoch, session) else {
                    try? await store.deleteThread(id: threadID)
                    return
                }
                let seedAction = turns.first?.action ?? Action.ask(question: question, withSelection: context.hasSelection)
                let convo = Conversation(
                    threadID: threadID,
                    originalSelection: sel,
                    operationClass: seedAction.operationClass,
                    turns: turns,
                    seedAskContext: askCtx
                )
                convo.provenance = provenance   // carry source chips onto the reloaded thread
                self.conversation = convo
                self.state = .visible(PanelContext(), .conversing)
                self.stashConversation(convo)
            } catch {
                guard self.stillCurrent(epoch, session) else { return }
                // Persisted, but a reload step threw: finalize in the conversation
                // surface rather than jumping to a one-shot result view.
                if liveConvo.turns.last?.role != .assistant {
                    liveConvo.turns.append(ConversationTurn(role: .assistant, text: assembled))
                }
                liveConvo.streamingText = ""
                liveConvo.isStreaming = false
            }
        }
    }

    /// Capture an eligible Ask conversation to the curation stash (ADR 0015) for the nightly
    /// dream cycle. Brain-gated and idempotent (one file per thread, overwritten), so calling
    /// it after the seed exchange and after each follow-up just keeps the latest transcript.
    /// No-op when the brain is off, there's no stash, or the thread isn't eligible (a bare
    /// quick-action transform). Failure is non-fatal — stashing must never break a reply.
    private func stashConversation(_ convo: Conversation) {
        guard BrainAccess.isActive, let stash = conversationStash,
              ConversationStash.isEligible(isAsk: convo.isAsk, turnCount: convo.turns.count) else { return }
        let stashed = StashedConversation(
            threadID: convo.threadID,
            isAsk: convo.isAsk,
            seedAction: convo.turns.first?.action?.rawValue ?? "",
            stampMillis: Int64(Date().timeIntervalSince1970 * 1000),
            turns: convo.turns.map {
                StashedTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text)
            })
        try? stash.stash(stashed)
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
            guard self.stillCurrent(epoch, session) else {
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
        defer { session.watchdogTask?.cancel() }
        armConversationWatchdog(convo, session: session, epoch: epoch, timeout: Self.firstTokenTimeout)
        var partial = ""
        do {
            for try await token in streaming.complete(messages: messages, sampling: sampling) {
                if Task.isCancelled { return }
                partial += token
                convo.streamingText = partial
                armConversationWatchdog(convo, session: session, epoch: epoch, timeout: Self.interTokenTimeout)
            }
            if Task.isCancelled { return }
            // The user may have accepted/navigated away as the last token arrived;
            // never append or persist a reply they no longer have open.
            guard stillCurrent(epoch, session) else { return }
            session.watchdogTask?.cancel()   // no more tokens; don't let it fire during persist
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
                stashConversation(convo)
            }
        } catch {
            if Task.isCancelled { return }
            guard stillCurrent(epoch, session) else { return }
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

    /// Copy-only accept: write the reply to the clipboard and dismiss, never
    /// pasting back over the source selection. Distinct from `acceptTurn` so an
    /// ask-with-selection bubble can offer BOTH — Replace (acceptTurn) when you
    /// want the answer to overwrite the selection, Copy (this) when you just
    /// want to keep it. Mirrors acceptTurn's single-flight + terminal teardown.
    func copyTurn(_ turn: ConversationTurn) {
        guard !isAccepting,
              turn.role == .assistant, conversation != nil, current != nil else { return }
        isAccepting = true
        bumpConvEpoch()
        current?.cancelStreaming()
        if let rowID = turn.interactionID {
            Task { try? await conversationStore?.markAccepted(interactionID: rowID) }
        }
        writeToClipboard(turn.text)
        state = .hidden; conversation = nil; current = nil; goIdle()
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
            // For ask threads, the attached selection lives on the seed interaction,
            // not in `originalSelection` (which holds the question). Without this,
            // `Conversation.messages` rebuilds the seed prompt against `.empty` and
            // the context block has nothing to show — a resumed ask-with-selection
            // follow-up would lose the source text it's meant to reason over.
            // Returns nil for non-ask threads, so non-ask resume is unaffected.
            let askCtx = try? await store.loadSeedAskContext(threadID: id)
            let provenance = (try? await store.loadProvenance(threadID: id)) ?? []
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
                                     operationClass: seed.operationClass, turns: turns,
                                     seedAskContext: askCtx)
            convo.provenance = provenance
            self.conversation = convo
            self.state = .visible(PanelContext(selection: sel, action: seed), .conversing)
        }
    }

    // MARK: - Profile (memory inspect/edit)

    /// Show the voice-card surface: `ProfileModel` loads the draft (no-op + no transition if
    /// memory is off); this method owns the panel transition.
    func showProfile() {
        guard profile.prepareForShow() else { return }
        state = .visible(state.context ?? PanelContext(selection: nil), .profile)
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
