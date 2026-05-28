import Foundation

/// Pure routing decision for the hotkey path, extracted from PanelController
/// so the no-selection → ask routing (and the single-capture invariant) can
/// be unit-tested without spinning up the full panel.
enum HotkeyRouting {
    enum Route: Equatable {
        case menu       // selection present — show the quick-action menu
        case ask        // no selection — show free-form ask input
    }

    static func route(for capture: TextIO.Capture) -> Route {
        let trimmed = (capture.selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .ask : .menu
    }
}
