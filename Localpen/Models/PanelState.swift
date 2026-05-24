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

    /// Stable per-phase key driving the menu→result cross-fade. Editing vs
    /// non-editing result get distinct keys so toggling edit mode animates;
    /// every other state maps to its case.
    var renderKey: Int {
        switch self {
        case .hidden:        return 0
        case .empty:         return 1
        case .captured:      return 2
        case .customPrompt:  return 3
        case .generating:    return 4
        case .result(_, _, _, let editing): return editing ? 6 : 5
        case .error:         return 7
        }
    }
}
