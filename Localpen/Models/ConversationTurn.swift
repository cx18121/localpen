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

    init(role: ConversationRole, text: String, action: Action? = nil) {
        self.role = role; self.text = text; self.action = action
    }

    static func == (lhs: ConversationTurn, rhs: ConversationTurn) -> Bool {
        lhs.role == rhs.role && lhs.text == rhs.text && lhs.action == rhs.action
    }
}
