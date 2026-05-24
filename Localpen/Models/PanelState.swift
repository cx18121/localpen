import Foundation

// State machine per SWIFTUI-SPEC.md §6 / DESIGN.md §4.
// Owned by PanelController; SwiftUI views observe via @Observable.
enum PanelState: Equatable {
    case hidden
    case empty
    case captured(Selection)
    case customPrompt(Selection?)
    case generating(Selection?, Action, partial: String)
    case result(Selection?, Action, finalResult: String, isEditing: Bool)
    case error(PanelError, prior: ErrorContext?)

    /// Captures enough state to retry whatever the user was doing when the
    /// error fired — selection + the action that was running (if any).
    struct ErrorContext: Equatable {
        let selection: Selection?
        let action: Action?
    }

    var isVisible: Bool {
        if case .hidden = self { return false }
        return true
    }
}
