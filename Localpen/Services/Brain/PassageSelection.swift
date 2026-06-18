import Foundation

/// Pure budget fill for the generic ask layer (W3): take chunks already ranked best-first
/// (mixed across candidate pages), emit `kb [Label]: <text>` lines until the token budget is
/// spent, capping chunks per page so one long note can't monopolize the slice. `linkedPaths`
/// marks pages pulled in via 1-hop graph expansion (for honest provenance).
enum PassageSelection {
    struct Pick: Equatable {
        let line: String; let title: String; let path: String; let isLinked: Bool; let tokens: Int
    }

    static func fill(ranked: [ChunkStore.ChunkRow], titleByPath: [String: String],
                     linkedPaths: Set<String>, budget: Int, perPageCap: Int) -> [Pick] {
        var out: [Pick] = []
        var remaining = budget
        var perPage: [String: Int] = [:]
        for ch in ranked {
            guard remaining > 0 else { break }
            guard (perPage[ch.path] ?? 0) < perPageCap else { continue }
            let title = titleByPath[ch.path] ?? ch.path
            let label = ch.heading.map { "\(title) › \($0)" } ?? title
            let line = "kb [\(label)]: \(ch.text)"
            let cost = ContextEngine.approxTokens(line)
            guard cost <= remaining else { continue }   // skip; a later smaller chunk may still fit
            out.append(Pick(line: line, title: title, path: ch.path,
                            isLinked: linkedPaths.contains(ch.path), tokens: cost))
            remaining -= cost
            perPage[ch.path, default: 0] += 1
        }
        return out
    }
}
