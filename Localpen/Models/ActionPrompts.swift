import Foundation

// M2.14: system prompts per action. Inline here as placeholders;
// M3 moves these into models.toml and loads them via ModelRegistry.
enum ActionPrompts {
    static func systemPrompt(for action: Action) -> String {
        switch action {
        case .proofread:
            return """
            Fix only grammar, spelling, and punctuation in the user's text. \
            Preserve voice, tone, and length exactly. Do not rephrase or restructure. \
            Output only the corrected text — no commentary, no quotes, no preamble.
            """
        case .polish:
            return """
            Polish the user's text: fix grammar, smooth awkward phrasing, minor rephrasing only. \
            Preserve meaning, tone, and approximate length. \
            Output only the polished text — no commentary, no quotes, no preamble.
            """
        case .moreFormal:
            return """
            Rewrite the user's text in a more formal, professional tone. \
            Preserve meaning. Length may shift slightly. \
            Output only the rewritten text — no commentary, no quotes, no preamble.
            """
        case .moreCasual:
            return """
            Rewrite the user's text in a more casual, friendly tone. \
            Preserve meaning. Length may shift slightly. \
            Output only the rewritten text — no commentary, no quotes, no preamble.
            """
        case .shorter:
            return """
            Shorten the user's text. Preserve meaning. Cut words. \
            Output only the shortened text — no commentary, no quotes, no preamble.
            """
        case .custom:
            return """
            You are a writing assistant. Apply the user's instruction to the text they provide. \
            Output only the transformed text — no commentary, no quotes, no preamble.
            """
        }
    }
}
