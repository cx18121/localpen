import Foundation

/// Turns a commit batch into a dated, scope-grouped, cited activity entry via the injected
/// synthesize closure. Clustering / prompt / span are pure; the two model calls (synthesize +
/// self-check) go through the closure so the pipeline is testable with a fake model.
enum ProjectActivitySynthesis {
    static func clusters(_ batch: ActivityBatch) -> [(scope: String, commits: [Commit])] {
        var order: [String] = []
        var byScope: [String: [Commit]] = [:]
        for c in batch.commits {
            let key = c.scope ?? "other"
            if byScope[key] == nil { order.append(key) }
            byScope[key, default: []].append(c)
        }
        return order.map { ($0, byScope[$0]!) }
    }

    static let system = """
        You write a project's activity log from its git commits. State ONLY what the commit \
        messages say was done. Do not infer outcomes, status, impact, or progress beyond the \
        text. Keep the scope groups you are given. Output one markdown bullet per scope: \
        "- **scope**: what was done (sha, sha)". Cite the short SHAs each bullet covers. No \
        preamble, no headings, no commentary.
        """

    static func prompt(for batch: ActivityBatch) -> String {
        var lines = ["Summarize these commits, grouped by scope:\n"]
        for (scope, commits) in clusters(batch) {
            let files = commits.reduce(0) { $0 + $1.filesChanged }
            lines.append("## \(scope) — \(commits.count) commit\(commits.count == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")")
            for c in commits {
                lines.append("- (\(c.sha)) \(c.subject)")
                if !c.body.isEmpty { lines.append("    \(c.body.replacingOccurrences(of: "\n", with: " "))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func selfCheckPrompt(draft: String, batch: ActivityBatch) -> String {
        """
        Commits:
        \(prompt(for: batch))

        Draft summary:
        \(draft)

        Remove any clause not directly supported by a commit message above. Return only the corrected bullets.
        """
    }

    static func spanHeader(_ batch: ActivityBatch) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
        let dates = batch.commits.map(\.date).sorted()
        let lo = f.string(from: dates.first ?? Date()), hi = f.string(from: dates.last ?? Date())
        return "### " + (lo == hi ? lo : "\(lo)–\(hi)")
    }

    static func entry(for batch: ActivityBatch,
                      synthesize: (_ system: String, _ user: String) async -> CurationOutcome) async -> String? {
        guard case .completed(let draft) = await synthesize(system, prompt(for: batch)),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard case .completed(let checked) = await synthesize(system, selfCheckPrompt(draft: draft, batch: batch)) else {
            return nil
        }
        let body = checked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "\(spanHeader(batch))\n\(body)"
    }
}
