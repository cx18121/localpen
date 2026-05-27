import Foundation

// Fallback action prompts used when the active model's `prompts` table is
// missing a field (or no active model is configured). The canonical prompts
// live in Resources/models.toml and are loaded via ModelRegistry. The Custom
// action's prompt always comes from here — it isn't model-specific.
enum ActionPrompts {
    /// Phase-2 voice injection point. Empty today: appended to generative
    /// system prompts so a learned style can be slotted in later with no
    /// structural change. Keep the leading space so concatenation reads
    /// cleanly when non-empty.
    static let styleContext: String = ""

    /// Assembles the user-role message for a generation. Fixed actions send the
    /// selection verbatim; `.custom` wraps the instruction around the text (or
    /// sends the instruction alone when there's no selection).
    static func userMessage(for action: Action, text: String) -> String {
        switch action {
        case .custom(let instruction):
            if text.isEmpty { return instruction }
            return "Instruction: \(instruction)\n\nText:\n\(text)"
        case .respond(let steer):
            let base = "Message to reply to:\n\(text)"
            return steer.isEmpty ? base : "\(base)\n\nHow to reply: \(steer)"
        default:
            return text
        }
    }

    static func systemPrompt(for action: Action) -> String {
        switch action {
        case .proofread:
            return """
            Fix only grammar, spelling, and punctuation in the user's text. \
            Preserve voice, tone, and length exactly. Do not rephrase or restructure. \
            Keep the original line breaks, blank lines, and indentation. \
            Output only the corrected text — no commentary, no quotes, no preamble.
            """
        case .polish:
            return """
            Polish the user's text: fix grammar, smooth awkward phrasing, minor rephrasing only. \
            Preserve meaning, tone, and approximate length. \
            Keep the original line breaks, blank lines, and paragraph structure. \
            Output only the polished text — no commentary, no quotes, no preamble.
            """
        case .moreFormal:
            return """
            Rewrite the user's text in a more formal, professional tone. \
            Preserve meaning. Length may shift slightly. \
            Keep the original line breaks and paragraph structure. \
            Output only the rewritten text — no commentary, no quotes, no preamble.
            """
        case .moreCasual:
            return """
            Rewrite the user's text in a more casual, friendly tone. \
            Preserve meaning. Length may shift slightly. \
            Keep the original line breaks and paragraph structure. \
            Output only the rewritten text — no commentary, no quotes, no preamble.
            """
        case .shorter:
            return """
            Shorten the user's text. Preserve meaning. Cut words. \
            Output only the shortened text — no commentary, no quotes, no preamble.
            """
        case .respond:
            return """
            Write a new reply to the message the user provides. Match a natural, \
            human email/message register. If the user includes an instruction, \
            follow it; otherwise write a concise, appropriate reply. \
            Output only the reply — no commentary, no quotes, no preamble, no subject line.
            """ + styleContext
        case .custom:
            return """
            You are a writing assistant. Apply the user's instruction to the text they provide. \
            Output only the transformed text — no commentary, no quotes, no preamble.
            """
        }
    }
}
