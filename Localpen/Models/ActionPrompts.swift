import Foundation

// Fallback action prompts used when the active model's `prompts` table is
// missing a field (or no active model is configured). The canonical prompts
// live in Resources/models.toml and are loaded via ModelRegistry. The Custom
// action's prompt always comes from here — it isn't model-specific.
enum ActionPrompts {
    /// Phase-2 voice injection point. Empty today: appended to generative
    /// system prompts so a learned style can be slotted in later with no
    /// structural change. If non-empty, it should begin with a space so
    /// concatenation reads cleanly.
    static let styleContext: String = ""

    /// Assembles the user-role message for a generation. Fixed actions send the
    /// selection verbatim; `.custom` wraps the instruction around the text (or
    /// sends the instruction alone when there's no selection).
    /// System prompt for multi-turn refinement threads. Deliberately generic so
    /// free-form follow-ups aren't constrained by a single action's framing. The
    /// seed action's instruction arrives as the first user message. `styleContext`
    /// is the Phase-2 voice seam (empty in Phase 1).
    static let conversationSystem: String = """
        You are a writing companion helping the user refine a piece of text over \
        several turns. The user's first message states what they want done with \
        the text that follows. Each later message is a refinement request. Always \
        return only the revised text, with no preamble, commentary, or quotation \
        marks. Keep the user's meaning and voice; change only what they ask for.
        """ + styleContext

    static func userMessage(for action: Action, text: String) -> String {
        switch action {
        case .custom(let instruction):
            if text.isEmpty { return instruction }
            return "Instruction: \(instruction)\n\nText:\n\(text)"
        case .respond(let steer):
            let base = "Message to reply to:\n\(text)"
            return steer.isEmpty ? base : "\(base)\n\nHow to reply: \(steer)"
        case .ask(let question, _):
            // Legacy text-only shape: callers that route through here pass
            // selection in `text`. PanelController's askSubmitted uses the
            // richer askUserMessage(question:context:) directly so the app
            // chip is included; this branch handles any indirect caller.
            return askUserMessage(
                question: question,
                context: AskContext(appLabel: nil,
                                    selection: text.isEmpty ? nil : text)
            )
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
        case .ask:
            return """
            You are Localpen, a local on-device assistant. Answer the user's \
            question directly and concisely. If the question is a draft request \
            (email, message, note), match the user's voice. If the user attaches \
            a <context> block, treat it as background; the question still drives \
            the response.
            """ + styleContext
        }
    }

    /// Builds the user-role message for an ask action. Renders surviving
    /// AskContext chips inside a `<context>` block; emits zero context lines
    /// when both chips are nil so the prompt is byte-identical to a
    /// chip-never-existed ask (Codex spec review §6). Both the app/window
    /// chip AND the selection chip reach the model (Codex plan review MED).
    static func askUserMessage(question: String, context: AskContext) -> String {
        // One ranked loop over everything (ADR 0019): ambient sources + the selection
        // operand + the knowledge brain, each tagged with a fixed `promptRank` so the
        // order is deterministic (app → selection → files → knowledge → calendar → …).
        // Nil/absent inputs add no line ⇒ byte-identical to a context-never-existed ask.
        var entries: [(rank: Int, line: String)] = context.sources.map { ($0.kind.promptRank, $0.promptLine) }
        if let sel = context.selection { entries.append((ContextKind.selection.promptRank, "selection: \(sel)")) }
        // Knowledge lines are pre-prefixed "kb [Title]: …" by ContextEngine.
        if let kb = context.knowledge { entries.append((ContextKind.knowledge.promptRank, kb)) }
        if entries.isEmpty { return question }
        let lines = entries.sorted { $0.rank < $1.rank }.map(\.line)
        return "<context>\n" + lines.joined(separator: "\n") + "\n</context>\n\n" + question
    }
}
