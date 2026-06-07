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

    /// Accepted in-place edits as instruction→output pairs. Excludes rows older than the
    /// Forget tombstone (`style_profile.forgotten_before`) so forgotten history never leaks
    /// into the training set — same durability guarantee as `Persistence.exportInteractionsJSON`.
    static func instructionPairs(db: DatabaseQueue) async throws -> [TrainingExample] {
        let rows = try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, selection, custom_prompt,
                       CASE WHEN edited_output IS NOT NULL AND length(edited_output) > 0
                            THEN edited_output ELSE model_output END AS final
                FROM interactions
                WHERE accepted = 1
                  AND selection IS NOT NULL AND length(selection) > 0
                  AND timestamp >= (SELECT forgotten_before FROM style_profile WHERE id = 1)
                ORDER BY id
                """)
        }
        return rows.compactMap { row in
            guard let instr = instruction(for: row["action"], customPrompt: row["custom_prompt"]),
                  let input: String = row["selection"],
                  let output: String = row["final"], !output.isEmpty else { return nil }
            return TrainingExample(instruction: instr, input: input, output: output)
        }
    }

    /// Raw-prose samples from the vault: frontmatter-stripped bodies, paragraph-packed
    /// into ~`maxChars` chunks. Excludes the usual non-content dirs (.obsidian/.git/raw).
    static func proseChunks(vaultRoot: URL, maxChars: Int = 1500) -> [String] {
        let excluded: Set<String> = [".obsidian", ".git", "raw"]
        var out: [String] = []
        // Sort by path: FileManager enumeration order isn't stable across runs, and the
        // positional train/heldout split downstream needs a reproducible chunk order.
        let files = BrainIndex.enumerateMarkdown(root: vaultRoot, excluding: excluded)
            .sorted { $0.path < $1.path }
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let body = MarkdownParser.splitFrontmatter(raw).body
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var buf = ""
            for para in body.components(separatedBy: "\n\n") {
                let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.isEmpty { continue }
                if buf.count + p.count > maxChars, !buf.isEmpty { out.append(buf); buf = "" }
                buf += buf.isEmpty ? p : "\n\n" + p
            }
            if !buf.isEmpty { out.append(buf) }
        }
        return out
    }

    /// Blend instruction pairs + prose (as empty-input examples) into one list, then
    /// split deterministically (every Nth row → holdout). Positional rather than random
    /// so the same input (pairs come from an `ORDER BY id` query) always yields the same
    /// train/heldout partition — reproducible dataset builds.
    static func jsonl(pairs: [TrainingExample], prose: [String],
                      holdoutEvery: Int = 8) -> (train: String, heldout: String) {
        let proseExamples = prose.map { TrainingExample(instruction: "Continue in the user's voice.", input: "", output: $0) }
        let all = pairs + proseExamples
        // .sortedKeys makes each line byte-stable: JSONEncoder's key order is otherwise
        // unspecified and varies run-to-run, which would make "reproducible" output differ
        // on disk even when the examples and split are identical.
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var train: [String] = [], held: [String] = []
        for (i, ex) in all.enumerated() {
            guard let data = try? enc.encode(ex), let line = String(data: data, encoding: .utf8) else { continue }
            if holdoutEvery > 0 && i % holdoutEvery == (holdoutEvery - 1) { held.append(line) } else { train.append(line) }
        }
        return (train.joined(separator: "\n"), held.joined(separator: "\n"))
    }
}
