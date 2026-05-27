import Foundation

enum Action: Hashable, Identifiable {
    case proofread
    case polish
    case moreFormal
    case moreCasual
    case shorter
    case respond(String)
    case custom(String)

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .proofread:   return "proofread"
        case .polish:      return "polish"
        case .moreFormal:  return "more_formal"
        case .moreCasual:  return "more_casual"
        case .shorter:     return "shorter"
        case .respond:     return "respond"
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
        case .respond:     return "Respond"
        case .custom:      return "Custom…"
        }
    }

    /// Same as `label` without the trailing affordance ellipsis — used where
    /// the action is shown as a static pill rather than a tappable menu item.
    var pillLabel: String { label.replacingOccurrences(of: "…", with: "") }

    static let fixed: [Action] = [.proofread, .polish, .moreFormal, .moreCasual, .shorter]

    enum OperationClass {
        /// Transforms the selection in place; output pastes back over it.
        case revise
        /// Uses the selection as a stimulus; output is a new artifact copied
        /// to the clipboard, never pasted back over the source.
        case create
    }

    /// Which class this action belongs to. Drives prompt framing AND accept
    /// behavior, so the two can't drift apart. Custom defaults to `.revise`
    /// (paste-back); the user can still copy a custom result instead.
    var operationClass: OperationClass {
        switch self {
        case .respond: return .create
        default:       return .revise
        }
    }

    /// The free-text the user supplied for the actions that carry one
    /// (the Custom instruction, the Respond steer). Persisted in
    /// `Interaction.customPrompt`.
    var steerText: String? {
        switch self {
        case .custom(let t):  return t.isEmpty ? nil : t
        case .respond(let t): return t.isEmpty ? nil : t
        default:              return nil
        }
    }

    /// Actions that produce a new artifact rather than revising the selection.
    static let createActions: [Action] = [.respond("")]

    /// Resolves the compose field's entered text into the action to generate,
    /// or nil when the submission should be ignored. Respond accepts empty
    /// (empty steer = a sensible default reply); Custom requires non-empty.
    static func fromCompose(base: Action, text: String) -> Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch base {
        case .custom:  return trimmed.isEmpty ? nil : .custom(trimmed)
        case .respond: return .respond(trimmed)
        default:       return nil
        }
    }
}
