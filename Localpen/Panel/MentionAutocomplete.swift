import Foundation

/// Pure logic for the `[[`/`@` mention autocomplete in the ask field (W2). Finding the active
/// token under the caret and filtering candidate titles are unit-testable here; the AppKit
/// wiring (showing the completion list, inserting the pick) lives in GrowingTextEditor.
enum MentionAutocomplete {
    enum Trigger: Equatable { case wiki, at }   // `[[…`  or  `@…`
    struct Token: Equatable { let range: NSRange; let query: String; let trigger: Trigger }

    /// Trigger prefix length: `[[` = 2, `@` = 1.
    static func triggerLength(_ t: Trigger) -> Int { t == .wiki ? 2 : 1 }

    /// The mention token immediately preceding `caret`, or nil. A `[[…` token runs to the caret
    /// with no closing `]`/`[`/newline; an `@…` token is `@` (at a word boundary) + non-space,
    /// non-bracket chars. When both are present, the one nearer the caret wins.
    static func activeToken(in nsText: NSString, caret: Int) -> Token? {
        guard caret >= 1, caret <= nsText.length else { return nil }
        let prefix = nsText.substring(to: caret) as NSString
        var best: Token?

        let wiki = prefix.range(of: "[[", options: .backwards)
        if wiki.location != NSNotFound {
            let q = prefix.substring(from: wiki.location + 2)
            if !q.contains("]") && !q.contains("[") && !q.contains("\n") {
                best = Token(range: NSRange(location: wiki.location, length: caret - wiki.location),
                             query: q, trigger: .wiki)
            }
        }

        let at = prefix.range(of: "@", options: .backwards)
        if at.location != NSNotFound, best == nil || at.location > best!.range.location {
            let okBefore = at.location == 0 ||
                prefix.substring(with: NSRange(location: at.location - 1, length: 1))
                    .rangeOfCharacter(from: .alphanumerics) == nil
            let q = prefix.substring(from: at.location + 1)
            let qOk = q.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n[]@")) == nil
            if okBefore && qOk {
                best = Token(range: NSRange(location: at.location, length: caret - at.location),
                             query: q, trigger: .at)
            }
        }
        return best
    }

    /// Titles matching `query` (case/format-insensitive substring), prefix matches first, capped.
    /// Empty query ⇒ the first `limit` titles (so just-typed `[[`/`@` shows something).
    static func filter(_ titles: [String], query: String, limit: Int) -> [String] {
        let q = normalize(query)
        guard !q.isEmpty else { return Array(titles.prefix(limit)) }
        let scored = titles.compactMap { title -> (title: String, prefix: Bool)? in
            let n = normalize(title)
            guard n.contains(q) else { return nil }
            return (title, n.hasPrefix(q))
        }
        return scored.sorted { $0.prefix && !$1.prefix }.map(\.title).prefix(limit).map { $0 }
    }

    /// The text a picked title is inserted as — always the wikilink form.
    static func replacement(for title: String) -> String { "[[\(title)]]" }

    private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
