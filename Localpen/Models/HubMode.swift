import Foundation

/// The hub's navigable areas (ADR 0016). A flat enum, not a protocol: modes are a
/// closed set and already mirror `PanelState.Phase`'s grain, so an exhaustive switch
/// is the feature. Owns identity + presentation metadata only — no view-building,
/// no behavior (those live in the per-mode views + PanelController).
enum HubMode: String, CaseIterable, Identifiable {
    case ask, kb, people, capture, now

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask:     return "Ask"
        case .kb:      return "Knowledge"
        case .people:  return "People"
        case .capture: return "Capture"
        case .now:     return "Now"
        }
    }

    var icon: String {
        switch self {
        case .ask:     return "sparkle"
        case .kb:      return "book.closed"
        case .people:  return "person.2"
        case .capture: return "tray.and.arrow.down"
        case .now:     return "doc.text"
        }
    }
}
