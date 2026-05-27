import Foundation

enum ConversationRole: Equatable { case user, assistant }

/// One bubble in the thread. `action` is set on the user turn that was a seed
/// action or a refinement chip; nil for a free-form typed follow-up. Identity
/// is a stable UUID for SwiftUI; equality compares content (so tests are stable
/// across UUIDs).
struct ConversationTurn: Identifiable, Equatable {
    let id = UUID()
    var role: ConversationRole
    var text: String
    var action: Action?
    /// The `interactions` row id for a persisted assistant turn (nil for user turns,
    /// the live streaming turn, or an ephemeral/unpersisted thread). Lets `acceptTurn`
    /// mark exactly the accepted exchange `accepted = true`.
    var interactionID: Int64?

    init(role: ConversationRole, text: String, action: Action? = nil, interactionID: Int64? = nil) {
        self.role = role; self.text = text; self.action = action; self.interactionID = interactionID
    }

    // Equality compares content only — `id` (SwiftUI identity) and `interactionID`
    // (persistence identity) are excluded so tests stay stable across them.
    static func == (lhs: ConversationTurn, rhs: ConversationTurn) -> Bool {
        lhs.role == rhs.role && lhs.text == rhs.text && lhs.action == rhs.action
    }
}
