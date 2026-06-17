import Foundation

/// Detects the people/projects a user named in a writing instruction (W2). Pure + total so
/// detection is unit-testable with a fixed candidate list. Explicit `[[name]]`/`@name` are
/// authoritative; auto-detection adds candidate titles that appear as whole words/phrases.
struct DetectedMention: Equatable {
    let title: String
    let type: KBPageType
    let origin: Origin
    enum Origin: Equatable { case explicit, auto }
}

struct MentionDetection: Equatable {
    var mentions: [DetectedMention] = []
    var unresolved: [String] = []
}

enum MentionResolver {
    static func detect(instruction: String, selection: String?, candidates: [KBPage]) -> MentionDetection {
        let haystack = [instruction, selection ?? ""].joined(separator: " ")
        var result = MentionDetection()
        var claimed = Set<String>()   // normalized titles already added

        // Index candidates by normalized title; shortest title wins a tie (most specific page).
        var byNorm: [String: KBPage] = [:]
        for p in candidates {
            let n = ProjectMatcher.normalize(p.title)
            if n.isEmpty { continue }
            if let existing = byNorm[n], existing.title.count <= p.title.count { continue }
            byNorm[n] = p
        }

        // 1. Explicit: [[name]] and @name (authoritative).
        for name in Self.explicitNames(in: instruction) + Self.explicitNames(in: selection ?? "") {
            let n = ProjectMatcher.normalize(name)
            guard !n.isEmpty, !claimed.contains(n) else { continue }
            if let page = byNorm[n] {
                claimed.insert(n)
                result.mentions.append(.init(title: page.title, type: page.type, origin: .explicit))
            } else if !result.unresolved.contains(name) {
                result.unresolved.append(name)
            }
        }

        // 2. Auto: candidate titles appearing as a contiguous whole-word phrase in the text.
        let textTokens = Self.wordTokens(haystack)
        for p in candidates {
            let n = ProjectMatcher.normalize(p.title)
            guard !n.isEmpty, !claimed.contains(n), byNorm[n]?.title == p.title else { continue }
            if Self.containsPhrase(Self.wordTokens(p.title), in: textTokens) {
                claimed.insert(n)
                result.mentions.append(.init(title: p.title, type: p.type, origin: .auto))
            }
        }
        return result
    }

    static func stripMarkup(_ text: String) -> String {
        var out = text
        // [[Anything]] → Anything  (keep inner text)
        out = out.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        // @Word → Word
        out = out.replacingOccurrences(of: #"@([\p{L}\p{N}_-]+)"#, with: "$1", options: .regularExpression)
        return out
    }

    // MARK: - helpers

    private static func explicitNames(in text: String) -> [String] {
        var names: [String] = []
        for m in matches(#"\[\[([^\]]+)\]\]"#, in: text) { names.append(m) }
        for m in matches(#"@([\p{L}\p{N}_-]+)"#, in: text) { names.append(m) }
        return names
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    /// Lowercased alphanumeric word tokens (so "Project Atlas" → ["project","atlas"]).
    private static func wordTokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// True if `needle` token sequence is a contiguous subsequence of `hay` (whole-word match).
    private static func containsPhrase(_ needle: [String], in hay: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start+needle.count]) == needle {
            return true
        }
        return false
    }
}
