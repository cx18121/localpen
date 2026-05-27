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

    /// Set when the latest turn's stream failed; ConversationView shows it inline
    /// with Retry. The failed user turn stays in `turns`, so retry just re-streams.
    var turnError: PanelError?

    /// True while a turn is being generated. Gates new submissions so a follow-up
    /// can't be sent mid-stream — that would abandon the in-flight turn and leave
    /// the live UI showing a user turn that never reaches persisted history.
    var isStreaming: Bool = false

    /// Invariant: if `turns` is non-empty, `turns[0]` must be a user turn whose
    /// `action` is non-nil — `messages` embeds the original selection only via that
    /// seed action. `seeded(...)` and `ConversationStore.loadTurns` both honor this.
    init(threadID: Int64, originalSelection: Selection,
         operationClass: Action.OperationClass, turns: [ConversationTurn]) {
        self.threadID = threadID
        self.originalSelection = originalSelection
        self.operationClass = operationClass
        self.turns = turns
    }

    /// Seeds a thread from a just-completed one-shot result plus the first
    /// follow-up: [user(seed action), assistant(result), user(follow-up)].
    static func seeded(threadID: Int64, originalSelection: Selection,
                       seedAction: Action, result: String, followUp: String) -> Conversation {
        Conversation(
            threadID: threadID,
            originalSelection: originalSelection,
            operationClass: seedAction.operationClass,
            turns: [
                ConversationTurn(role: .user, text: seedAction.pillLabel, action: seedAction),
                ConversationTurn(role: .assistant, text: result),
                ConversationTurn(role: .user, text: followUp)
            ]
        )
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
                    return ("user", ActionPrompts.userMessage(for: action, text: originalSelection.text))
                }
                return ("user", turn.text)
            }
        }
    }
}
