import Foundation

// Selection + active action, shared by every visible state. Carrying these in
// one place (rather than re-threading them through each case, and re-carrying
// them in an error envelope) means retry-after-error is "same context, new
// phase" and there is exactly one place to read the selection from. See
// THERMO-REVIEW #7.
struct PanelContext: Equatable {
    var selection: Selection?
    var action: Action?
}

// State machine per SWIFTUI-SPEC.md §6 / DESIGN.md §4.
// Owned by PanelController; SwiftUI views observe via @Observable.
enum PanelState: Equatable {
    case hidden
    case visible(PanelContext, Phase)

    // What the visible panel is currently showing. The selection/action it
    // operates on live in the accompanying PanelContext, not here.
    enum Phase: Equatable {
        case empty
        case captured
        case customPrompt
        // The streamed text lives in PanelController.streamingText (a separate
        // observed property) so per-token updates re-render only the result
        // region, not the whole panel.
        case generating
        case conversing
        case history
        case profile
        case result(finalResult: String, isEditing: Bool)
        case error(PanelError)
    }

    var isVisible: Bool {
        if case .visible = self { return true }
        return false
    }

    /// The selection + action the panel is operating on, or nil when hidden.
    var context: PanelContext? {
        if case .visible(let ctx, _) = self { return ctx }
        return nil
    }

    /// Stable per-phase key driving the menu→result cross-fade. Editing vs
    /// non-editing result get distinct keys so toggling edit mode animates;
    /// every other state maps to its phase.
    var renderKey: Int {
        guard case .visible(_, let phase) = self else { return 0 }
        switch phase {
        case .empty:        return 1
        case .captured:     return 2
        case .customPrompt: return 3
        case .generating:   return 4
        case .result(_, let editing): return editing ? 6 : 5
        case .error:        return 7
        case .conversing:   return 8
        case .history:      return 9
        case .profile:      return 10
        }
    }
}
