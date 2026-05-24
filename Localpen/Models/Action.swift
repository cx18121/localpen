import Foundation

enum Action: Hashable, Identifiable {
    case proofread
    case polish
    case moreFormal
    case moreCasual
    case shorter
    case custom(String)

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .proofread:   return "proofread"
        case .polish:      return "polish"
        case .moreFormal:  return "more_formal"
        case .moreCasual:  return "more_casual"
        case .shorter:     return "shorter"
        case .custom:      return "custom"
        }
    }

    var label: String {
        switch self {
        case .proofread:   return "Proofread"
        case .polish:      return "Polish"
        case .moreFormal:  return "More formal"
        case .moreCasual:  return "More casual"
        case .shorter:     return "Shorter"
        case .custom:      return "Custom…"
        }
    }

    static let fixed: [Action] = [.proofread, .polish, .moreFormal, .moreCasual, .shorter]
}
