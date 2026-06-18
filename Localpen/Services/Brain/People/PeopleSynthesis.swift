import Foundation

/// Pure parsing/formatting helpers for the people-synthesis pass (no I/O). All methods
/// are stateless so they're testable without any mock collaborators.
enum PeopleSynthesis {
    /// The raw `- ` bullets under the `## Connections` heading of a page body (trimmed, in
    /// order). Stops at the next `## ` heading or `---` rule or EOF. Returns [] if the
    /// section is absent or empty.
    static func connections(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        var inSection = false
        var bullets: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Connections" { inSection = true; continue }
            if inSection {
                if trimmed.hasPrefix("## ") || trimmed == "---" { break }
                if trimmed.hasPrefix("- ") {
                    bullets.append(String(trimmed.dropFirst(2)))
                }
            }
        }
        return bullets
    }

    /// A stable fingerprint of the raw connection bullets, so the pass only re-synthesizes
    /// when they change. Just the bullets joined by "\n" (stable + simple).
    static func fingerprint(_ connections: [String]) -> String {
        connections.joined(separator: "\n")
    }

    /// System prompt: faithful/extractive.
    static let system: String = "You maintain a person dossier. From the raw facts, write (1) a 2-4 sentence synthesized 'Compiled Truth' summary and (2) a deduplicated, merged bullet list of the distinct facts. State ONLY what the facts say — do not invent, infer, or drop information; only remove redundancy and merge paraphrases. Output EXACTLY: `SUMMARY:` then the summary, a blank line, then `FACTS:` then `- ` bullets. No other text."

    /// User prompt: the person's name + their raw connection bullets.
    static func prompt(name: String, connections: [String]) -> String {
        let bullets = connections.map { "- \($0)" }.joined(separator: "\n")
        return "Person: \(name)\n\nRaw facts:\n\(bullets)"
    }

    /// Parse the model response in the SUMMARY/FACTS format into (compiledTruth, connections).
    /// Returns nil if either section is missing/empty (caller skips the write). Tolerant of
    /// leading/trailing whitespace and an optional blank line between sections.
    static func parse(_ raw: String) -> (compiledTruth: String, connections: [String])? {
        let lines = raw.components(separatedBy: "\n")
        var summaryLines: [String] = []
        var factsLines: [String] = []
        var inSummary = false
        var inFacts = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "SUMMARY:" { inSummary = true; inFacts = false; continue }
            if trimmed == "FACTS:" { inFacts = true; inSummary = false; continue }
            if inSummary { summaryLines.append(line) }
            if inFacts   { factsLines.append(line) }
        }
        let summary = summaryLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bullets: [String] = factsLines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            return String(t.dropFirst(2))
        }
        guard !summary.isEmpty, !bullets.isEmpty else { return nil }
        return (compiledTruth: summary, connections: bullets)
    }
}
