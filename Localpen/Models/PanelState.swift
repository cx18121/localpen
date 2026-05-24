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
    case error(PanelError)

    var isVisible: Bool {
        if case .hidden = self { return false }
        return true
    }
}
