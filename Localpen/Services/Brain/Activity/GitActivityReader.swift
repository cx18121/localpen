import Foundation

/// Reads + parses a repo's git history into structured commits for the project-activity
/// pass (project-activity-freshness spec). Parsing is pure (testable with `git log` fixtures);
/// `read` shells git. Relies on the conventional-commit discipline the user already follows.
struct Commit: Equatable {
    let sha: String
    let date: Date
    let type: String
    let scope: String?
    let subject: String
    let body: String
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
}

enum GitActivityReader {
    /// Trivia types excluded from activity summaries.
    private static let trivialTypes: Set<String> = ["chore", "style", "build", "ci"]

    static func parse(_ rawLog: String) -> [Commit] {
        // Each commit: "@@C@@\u{1f}sha\u{1f}date\u{1f}subject\u{1f}body…\u{1f}@@E@@" then a
        // --shortstat line. Split on the "@@C@@\u{1f}" record opener.
        let records = rawLog.components(separatedBy: "@@C@@\u{1f}").dropFirst()
        var out: [Commit] = []
        for rec in records {
            guard let endRange = rec.range(of: "\u{1f}@@E@@") else { continue }
            let head = String(rec[rec.startIndex..<endRange.lowerBound])
            let fields = head.components(separatedBy: "\u{1f}")
            guard fields.count >= 4 else { continue }
            let sha = fields[0]
            let date = parseDate(fields[1])
            let rawSubject = fields[2]
            let body = fields[3...].joined(separator: "\u{1f}").trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(rec[endRange.upperBound...])
            let stat = parseShortstat(after)
            let (type, scope, subject) = splitConventional(rawSubject)
            out.append(Commit(sha: sha, date: date, type: type, scope: scope, subject: subject,
                              body: body, filesChanged: stat.files, insertions: stat.ins, deletions: stat.del))
        }
        return out
    }

    static func substantive(_ commits: [Commit]) -> [Commit] {
        commits.filter { !trivialTypes.contains($0.type) }
    }

    /// Parses a date from either a full ISO 8601 datetime (real `git log %aI`,
    /// e.g. "2026-06-17T14:22:11+05:30") or a date-only string ("2026-06-17").
    /// Returns epoch on complete parse failure.
    private static func parseDate(_ s: String) -> Date {
        let full = ISO8601DateFormatter()          // default options handle full datetimes
        if let d = full.date(from: s) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let d = dateOnly.date(from: s) { return d }
        return Date(timeIntervalSince1970: 0)
    }

    /// "feat(w2): text" → ("feat","w2","text"); "fix: text" → ("fix",nil,"text");
    /// "plain msg" → ("",nil,"plain msg").
    private static func splitConventional(_ s: String) -> (type: String, scope: String?, subject: String) {
        guard let colon = s.firstIndex(of: ":") else { return ("", nil, s.trimmingCharacters(in: .whitespaces)) }
        let prefix = String(s[s.startIndex..<colon])
        let rest = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // prefix is "type" or "type(scope)" — and must look like a type token (no spaces).
        guard !prefix.contains(" ") else { return ("", nil, s.trimmingCharacters(in: .whitespaces)) }
        if let open = prefix.firstIndex(of: "("), prefix.hasSuffix(")") {
            let type = String(prefix[prefix.startIndex..<open])
            let scope = String(prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)])
            return (type, scope.isEmpty ? nil : scope, rest)
        }
        return (prefix, nil, rest)
    }

    /// " 3 files changed, 40 insertions(+), 5 deletions(-)" → (3,40,5). Missing parts → 0.
    private static func parseShortstat(_ s: String) -> (files: Int, ins: Int, del: Int) {
        func num(_ pattern: String) -> Int {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return 0 }
            return Int(s[r].prefix(while: { $0.isNumber })) ?? 0
        }
        return (num(#"\d+ files? changed"#), num(#"\d+ insertions?\(\+\)"#), num(#"\d+ deletions?\(-\)"#))
    }
}
