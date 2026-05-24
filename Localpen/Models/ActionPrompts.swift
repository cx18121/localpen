import Foundation

// Fallback action prompts used when the active model's `prompts` table is
// missing a field (or no active model is configured). The canonical prompts
// live in Resources/models.toml and are loaded via ModelRegistry. The Custom
// action's prompt always comes from here — it isn't model-specific.
enum ActionPrompts {
    /// Assembles the user-role message for a generation. Fixed actions send the
    /// selection verbatim; `.custom` wraps the instruction around the text (or
    /// sends the instruction alone when there's no selection).
    static func userMessage(for action: Action, text: String) -> String {
        if case let .custom(instruction) = action {
            if text.isEmpty { return instruction }
            return "Instruction: \(instruction)\n\nText:\n\(text)"
        }
        return text
    }

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
