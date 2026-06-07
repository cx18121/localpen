import Foundation

/// Pure word-level diff for showing what a rewrite changed. Tokenizes into word and
/// non-word (whitespace/punctuation) runs so layout — including newlines — survives,
/// then LCS-diffs the token streams into ordered spans. Feeds the result panel only;
/// best-effort and never throws.
enum TextDiff {
    enum Span: Equatable { case equal(String), insert(String), delete(String) }

    static func hasChanges(_ spans: [Span]) -> Bool {
        spans.contains { if case .equal = $0 { return false } else { return true } }
    }

    /// Word-granular spans from `original` → `revised`.
    static func spans(original: String, revised: String) -> [Span] {
        let a = tokenize(original), b = tokenize(revised)
        let ops = lcsDiff(a, b)
        // Merge adjacent same-kind ops into single spans for clean rendering.
        var out: [Span] = []
        func append(_ span: Span) {
            if case .equal(let s) = span, case .equal(let p)? = out.last { out[out.count-1] = .equal(p+s); return }
            if case .insert(let s) = span, case .insert(let p)? = out.last { out[out.count-1] = .insert(p+s); return }
            if case .delete(let s) = span, case .delete(let p)? = out.last { out[out.count-1] = .delete(p+s); return }
            out.append(span)
        }
        for op in ops { append(op) }
        return out
    }

    /// Split into runs: a maximal run of alphanumerics is one token; every other
    /// character (space, newline, punctuation) is its own token. Reassembling all
    /// tokens reproduces the input exactly.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(ch))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    /// Standard LCS backtrack → ordered equal/delete/insert spans (token-level).
    private static func lcsDiff(_ a: [String], _ b: [String]) -> [Span] {
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i+1][j+1] + 1 : max(dp[i+1][j], dp[i][j+1])
            }
        }
        var i = 0, j = 0, out: [Span] = []
        while i < n && j < m {
            if a[i] == b[j] { out.append(.equal(a[i])); i += 1; j += 1 }
            else if dp[i+1][j] >= dp[i][j+1] { out.append(.delete(a[i])); i += 1 }
            else { out.append(.insert(b[j])); j += 1 }
        }
        while i < n { out.append(.delete(a[i])); i += 1 }
        while j < m { out.append(.insert(b[j])); j += 1 }
        return out
    }
}
