import Foundation
import Observation

/// A live, multi-turn refinement thread. Owned by PanelController; ConversationView
/// observes it. `streamingText` holds the in-flight assistant reply so per-token
/// updates re-render only the latest bubble (mirrors PanelController.streamingText).
@MainActor
@Observable
final class Conversation {
    let threadID: Int64
    let originalSelection: Selection
    let operationClass: Action.OperationClass
    var turns: [ConversationTurn]
    var streamingText: String = ""

    /// The KB pages a brain-backed ask drew on (ADR 0014 provenance). Shown as clickable
    /// source chips in the conversation surface. Empty for non-brain asks / writing threads.
    var provenance: [ContextBundle.Provenance] = []

    /// Set when the latest turn's stream failed; ConversationView shows it inline
    /// with Retry. The failed user turn stays in `turns`, so retry just re-streams.
    var turnError: PanelError?

    /// True while a turn is being generated. Gates new submissions so a follow-up
    /// can't be sent mid-stream — that would abandon the in-flight turn and leave
    /// the live UI showing a user turn that never reaches persisted history.
    var isStreaming: Bool = false

    /// For ask threads, the chip context at submit time. Used by `messages`
    /// to rebuild the seed user message via `askUserMessage` on resume.
    /// Without this, the rebuilt seed would wrap the question as its own
    /// selection chip (since `originalSelection.text` is the question for
    /// ask threads). Nil for non-ask threads.
    let seedAskContext: AskContext?

    /// Invariant: if `turns` is non-empty, `turns[0]` must be a user turn whose
    /// `action` is non-nil — `messages` embeds the original selection only via that
    /// seed action. `seeded(...)` and `ConversationStore.loadTurns` both honor this.
    init(threadID: Int64, originalSelection: Selection,
         operationClass: Action.OperationClass, turns: [ConversationTurn],
         seedAskContext: AskContext? = nil) {
        self.threadID = threadID
        self.originalSelection = originalSelection
        self.operationClass = operationClass
        self.turns = turns
        self.seedAskContext = seedAskContext
    }

    /// Seeds a thread from a just-completed one-shot result plus the first
    /// follow-up: [user(seed action), assistant(result), user(follow-up)].
    static func seeded(threadID: Int64, originalSelection: Selection,
                       seedAction: Action, result: String, followUp: String,
                       seedAskContext: AskContext? = nil) -> Conversation {
        Conversation(
            threadID: threadID,
            originalSelection: originalSelection,
            operationClass: seedAction.operationClass,
            turns: [
                ConversationTurn(role: .user, text: seedAction.pillLabel, action: seedAction),
                ConversationTurn(role: .assistant, text: result),
                ConversationTurn(role: .user, text: followUp)
            ],
            seedAskContext: seedAskContext
        )
    }

    /// True when this thread was started by a free-form Ask (its seed action is
    /// `.ask`). The conversation surface reads this to suppress the writing-only
    /// refinement chips (Soften/Tighten/More formal/More casual), which are
    /// follow-ups for a writing transform and meaningless for a Q&A answer.
    /// Reliable on resume too: `loadTurns` reconstructs the seed action from the
    /// persisted `action='ask'` row.
    var isAsk: Bool {
        guard let seedAction = turns.first?.action else { return false }
        if case .ask = seedAction { return true }
        return false
    }

    /// The OpenAI-style message array (excluding the system message, which the
    /// controller prepends). The first user turn embeds the original selection
    /// via the seed action's user message; later user turns are raw follow-ups.
    var messages: [(role: String, content: String)] {
        turns.enumerated().map { idx, turn in
            switch turn.role {
            case .assistant:
                return ("assistant", turn.text)
            case .user:
                if idx == 0, let action = turn.action {
                    // Codex HIGH 2: ask rebuilds via structured
                    // askUserMessage so the question doesn't get wrapped
                    // as its own selection context.
                    if case .ask(let q, _) = action {
                        let ctx = seedAskContext ?? AskContext.empty
                        return ("user", ActionPrompts.askUserMessage(question: q, context: ctx))
                    }
                    return ("user", ActionPrompts.userMessage(for: action, text: originalSelection.text))
                }
                return ("user", turn.text)
            }
        }
    }
}
