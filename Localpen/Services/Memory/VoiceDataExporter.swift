import Foundation
import GRDB

/// Builds voice fine-tuning data from the user's own writing: accepted in-place edits
/// (instruction→output pairs) + cxkb prose (raw text). Pure + injectable so it's
/// testable without the live stores. No training here — just the dataset.
enum VoiceDataExporter {
    struct TrainingExample: Codable, Equatable {
        let instruction: String
        let input: String      // "" for raw-prose samples
        let output: String
    }

    /// In-place transform actions only — these are genuine "the user rewrites text in
    /// their voice" signal. respond/ask are excluded: their selection is third-party and
    /// their output is model-composed (drift), matching MemoryAttribution's policy.
    static func instruction(for action: String, customPrompt: String?) -> String? {
        switch action {
        case "proofread":   return "Proofread this text, fixing grammar, spelling, and punctuation."
        case "polish":      return "Polish this text."
        case "more_formal": return "Rewrite this text in a more formal tone."
        case "more_casual": return "Rewrite this text in a more casual tone."
        case "shorter":     return "Make this text shorter."
        case "custom":
            let c = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? nil : c          // custom uses the user's own instruction
        default:            return nil           // respond/ask/etc. excluded
        }
    }

    static func instructionPairs(db: DatabaseQueue) async throws -> [TrainingExample] {
        let rows = try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, selection, custom_prompt,
                       CASE WHEN edited_output IS NOT NULL AND length(edited_output) > 0
                            THEN edited_output ELSE model_output END AS final
                FROM interactions
                WHERE accepted = 1
                  AND selection IS NOT NULL AND length(selection) > 0
                """)
        }
        return rows.compactMap { row in
            guard let instr = instruction(for: row["action"], customPrompt: row["custom_prompt"]),
                  let input: String = row["selection"],
                  let output: String = row["final"], !output.isEmpty else { return nil }
            return TrainingExample(instruction: instr, input: input, output: output)
        }
    }
}
