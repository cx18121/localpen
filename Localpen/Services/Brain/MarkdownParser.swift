import Foundation

/// Parses one vault markdown file into a `KBPage`. Injectable so `BrainIndex` tests
/// can stub it. No YAML dependency — the vault's frontmatter is flat scalars + simple
/// lists (the documented schema), so a hand-rolled line parser covers it and a
/// malformed file still indexes its body (fail-loud at the index, not the file).
protocol MarkdownParsing: Sendable {
    func parse(url: URL, vaultRoot: URL) -> KBPage?
}

struct MarkdownParser: MarkdownParsing {
    func parse(url rawURL: URL, vaultRoot: URL) -> KBPage? {
        // Canonicalize: the FileManager enumerator can hand back symlink-resolved paths
        // (/var → /private/var on macOS), so `path` — the index's primary key — must be
        // resolved consistently or reindexAll and the watcher desync into duplicate rows.
        let url = rawURL.resolvingSymlinksInPath()
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (frontmatter, body) = Self.splitFrontmatter(raw)
        let title = url.deletingPathExtension().lastPathComponent
        let area = Self.area(of: url, vaultRoot: vaultRoot)
        let type = Self.isJournalName(title) ? .journal : KBPageType(frontmatter: frontmatter["type"])
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return KBPage(path: url.path, title: title, type: type, area: area,
                      body: body, outboundLinks: Self.wikilinks(in: body),
                      tags: Self.tags(frontmatter["tags"]),
                      mtime: mtime, frontmatter: frontmatter)
    }

    // MARK: - Pure helpers (individually unit-tested)

    /// Leading `---` line → take up to the next `---` line as frontmatter, rest as body.
    /// No leading fence ⇒ ([:], whole input).
    static func splitFrontmatter(_ raw: String) -> (frontmatter: [String: String], body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], raw) }
        var close: Int?
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i; break
        }
        guard let end = close else { return ([:], raw) }
        let fm = parseFrontmatterLines(Array(lines[1..<end]))
        let body = end + 1 <= lines.count - 1 ? lines[(end + 1)...].joined(separator: "\n") : ""
        return (fm, body)
    }

    /// Flat `key: value` scalars, inline `[a, b]` lists, and block `- item` lists.
    private static func parseFrontmatterLines(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Only top-level `key:` lines (not indented continuations / list items).
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                // Possible block list on following indented `- ` lines.
                var items: [String] = []
                var j = i + 1
                while j < lines.count {
                    let l = lines[j].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("- ") else { break }
                    items.append(String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    j += 1
                }
                if !items.isEmpty {
                    out[key] = "[" + items.joined(separator: ", ") + "]"
                    i = j; continue
                }
            }
            if !key.isEmpty { out[key] = value }
            i += 1
        }
        return out
    }

    /// `[[Title]]` / `[[Title|alias]]` → "Title" (alias dropped), de-duped (case-insensitive)
    /// preserving first-seen order.
    static func wikilinks(in body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]") else { return [] }
        let ns = body as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// Journal filename convention: `YYYY-MM-DD`. Forces `type = .journal`.
    static func isJournalName(_ title: String) -> Bool {
        title.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
    }

    /// Inline `[a, b]` or a bare scalar → `[scalar]`. Empty ⇒ [].
    static func tags(_ raw: String?) -> [String] {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// First path component under the vault root; "" for a root-level file.
    static func area(of url: URL, vaultRoot: URL) -> String {
        let root = vaultRoot.standardizedFileURL.pathComponents
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count > root.count, Array(comps.prefix(root.count)) == root else { return "" }
        let rel = Array(comps.dropFirst(root.count))
        return rel.count >= 2 ? rel[0] : ""
    }
}
