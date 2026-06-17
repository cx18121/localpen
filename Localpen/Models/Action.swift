import Foundation

enum Action: Hashable, Identifiable {
    case proofread
    case polish
    case moreFormal
    case moreCasual
    case shorter
    case respond(String)
    case custom(String)
    /// Free-form ask. `withSelection` is decided at submit time from whether
    /// the AskContext selection chip survived; `operationClass` derives from
    /// it so the existing accept-path predicate (`operationClass == .revise`)
    /// works unchanged. The flag is NOT serialized in `rawValue`; it's
    /// rehydrated on resume by reading the persisted Interaction row's
    /// `selection` column (passed to `reconstruct`).
    case ask(question: String, withSelection: Bool)

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
        case .ask:         return "ask"
        }
    }

    /// Inverse of `rawValue`. `selection` is read from the persisted
    /// Interaction row and only consulted for `.ask` (to rehydrate the
    /// `withSelection` flag). Existing cases ignore it, so the signature
    /// extension is additive.
    static func reconstruct(rawValue: String, steer: String?, selection: String? = nil) -> Action {
        switch rawValue {
        case "proofread":   return .proofread
        case "polish":      return .polish
        case "more_formal": return .moreFormal
        case "more_casual": return .moreCasual
        case "shorter":     return .shorter
        case "respond":     return .respond(steer ?? "")
        case "ask":
            return .ask(question: steer ?? "",
                        withSelection: !(selection ?? "").isEmpty)
        default:            return .custom(steer ?? "")
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
        case .ask:         return "Ask"
        }
    }

    /// Same as `label` without the trailing affordance ellipsis — used where
    /// the action is shown as a static pill rather than a tappable menu item.
    var pillLabel: String { label.replacingOccurrences(of: "…", with: "") }

    /// The seed-turn rendering inside a conversation thread: a plain-English
    /// sentence the user "said" to start the thread, so the bubble reads like
    /// a real message instead of a cryptic tag ("Proofread"). For `.custom` /
    /// `.respond` / `.ask` we use the user's actual steer text when present.
    var seedSentence: String {
        switch self {
        case .proofread:                  return "Proofread this"
        case .polish:                     return "Polish this"
        case .moreFormal:                 return "Make this more formal"
        case .moreCasual:                 return "Make this more casual"
        case .shorter:                    return "Make this shorter"
        case .respond(let steer):         return steer.isEmpty ? "Respond to this" : steer
        case .custom(let instr):          return instr.isEmpty ? "Custom instruction" : instr
        case .ask(let q, _):              return q.isEmpty ? "Ask" : q
        }
    }

    static let fixed: [Action] = [.proofread, .polish, .moreFormal, .moreCasual, .shorter]

    enum OperationClass {
        /// Transforms the selection in place; output pastes back over it.
        case revise
        /// Uses the selection as a stimulus; output is a new artifact copied
        /// to the clipboard, never pasted back over the source.
        case create
    }

    /// Which class this action belongs to. Drives prompt framing AND accept
    /// behavior, so the two can't drift apart. .ask: revise iff a selection
    /// chip survived submit; otherwise create.
    var operationClass: OperationClass {
        switch self {
        case .respond:                    return .create
        case .ask(_, let withSelection):  return withSelection ? .revise : .create
        default:                          return .revise
        }
    }

    /// Actions whose user-supplied instruction can name a person/project to ground on (W2).
    /// The 6 fixed quick-actions carry no instruction, so they never ground.
    var groundsInBrain: Bool {
        switch self {
        case .respond, .custom, .ask: return true
        default:                      return false
        }
    }

    /// The free-text the user supplied for the actions that carry one
    /// (the Custom instruction, the Respond steer, the Ask question).
    /// Persisted in `Interaction.customPrompt`.
    var steerText: String? {
        switch self {
        case .custom(let t):       return t.isEmpty ? nil : t
        case .respond(let t):      return t.isEmpty ? nil : t
        case .ask(let q, _):       return q.isEmpty ? nil : q
        default:                   return nil
        }
    }

    /// Resolves the compose field's entered text into the action to generate,
    /// or nil when the submission should be ignored. Respond accepts empty
    /// (empty steer = a sensible default reply); Custom and Ask require non-empty.
    static func fromCompose(base: Action, text: String) -> Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch base {
        case .custom:  return trimmed.isEmpty ? nil : .custom(trimmed)
        case .respond: return .respond(trimmed)
        case .ask(_, let withSelection):
            return trimmed.isEmpty ? nil : .ask(question: trimmed, withSelection: withSelection)
        default:       return nil
        }
    }
}
