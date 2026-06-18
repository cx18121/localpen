import Foundation

/// The hub's navigable areas (ADR 0016). A flat enum, not a protocol: modes are a
/// closed set and already mirror `PanelState.Phase`'s grain, so an exhaustive switch
/// is the feature. Owns identity + presentation metadata only — no view-building,
/// no behavior (those live in the per-mode views + PanelController).
enum HubMode: String, CaseIterable, Identifiable {
    // Four modes (ADR 0024): Today is the home glance and absorbs the former Now / Capture /
    // Suggestions; People stays as the browsable CRM. A persisted legacy raw value
    // (now/capture/suggestions) decodes to nil and callers fall back to `.ask`.
    case today, ask, kb, people

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:   return "Today"
        case .ask:     return "Ask"
        case .kb:      return "Notes"
        case .people:  return "People"
        }
    }

    var icon: String {
        switch self {
        case .today:   return "sun.max"
        case .ask:     return "sparkle"
        case .kb:      return "book.closed"
        case .people:  return "person.2"
        }
    }
}
