import Foundation

/// Formats grounding for a resolved mention (W2): a one-line orientation header + cosine-ranked
/// chunk selection. Pure so ranking/formatting are unit-testable without a DB or server.
enum MentionGrounding {
    static func personHeader(_ p: PeopleInsights.Person) -> String? {
        var parts = ["\(p.tier) tier"]
        if let d = p.daysSinceContact { parts.append("last contact \(d)d ago") }
        if let f = p.followUp { parts.append("follow-up: \(f)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func projectHeader(_ page: KBPage) -> String? {
        let fields = ["status", "stage"].compactMap { key -> String? in
            PeopleInsights.cleaned(page.frontmatter[key]).map { "\(key): \($0)" }
        }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    static func rankChunks(_ chunks: [ChunkStore.ChunkRow], queryVector: [Float], limit: Int) -> [ChunkStore.ChunkRow] {
        chunks
            .map { (row: $0, sim: VectorMath.cosine(queryVector, $0.vector)) }
            .sorted { $0.sim > $1.sim }
            .prefix(limit)
            .map(\.row)
    }

    /// One resolved entity's grounding material, pre-ranked. `ownChunks` are the entity page's
    /// chunks (best first); `neighborChunks` are chunks of pages that link to it (its backlink
    /// neighborhood — meetings/projects it appears in), each tagged with the neighbor's title.
    struct EntityContent: Equatable {
        let title: String
        let path: String
        let header: String?
        let ownChunks: [ChunkStore.ChunkRow]
        let neighborChunks: [NeighborChunk]
    }
    struct NeighborChunk: Equatable { let neighborTitle: String; let chunk: ChunkStore.ChunkRow }

    /// One assembled `kb […]: …` line plus its provenance (title + path; reason is always
    /// `.mention`). `tokens` is the budget this line consumed (so the caller can decrement).
    struct GroundLine: Equatable { let title: String; let path: String; let text: String; let tokens: Int }

    /// Pack grounding into the token `budget`, primary-slice-first: every entity gets its
    /// header + top-ranked own chunk (split evenly across entities) BEFORE any entity's extra
    /// chunks or neighborhood is funded. So `[[Ana]] and [[Ben]]` both land before either's
    /// backlinks. Pure — testable with hand-built content, no DB/server.
    static func assemble(_ entities: [EntityContent], budget: Int) -> [GroundLine] {
        var out: [GroundLine] = []
        var remaining = budget
        var headerEmitted = Set<String>()   // entity path

        func tryEmit(title: String, path: String, label: String, snippet: String) -> Bool {
            let cost = ContextEngine.approxTokens(snippet)
            guard cost <= remaining else { return false }
            out.append(GroundLine(title: title, path: path, text: "kb [\(label)]: \(snippet)", tokens: cost))
            remaining -= cost
            return true
        }

        // Pass 1 — primary slice: header + top own chunk per entity (or header alone, or the
        // condensed-fallback already baked into ownChunks[0] when embeddings were absent).
        for e in entities {
            guard remaining > 0 else { break }
            let label = e.ownChunks.first?.heading.map { "\(e.title) › \($0)" } ?? e.title
            let snippet = [e.header, e.ownChunks.first?.text].compactMap { $0 }.joined(separator: " — ")
            guard !snippet.isEmpty else { continue }
            if tryEmit(title: e.title, path: e.path, label: label, snippet: snippet) {
                headerEmitted.insert(e.path)
            }
        }

        // Pass 2 — enrichment, round-robin so no single entity hogs the rest: remaining own
        // chunks first, then neighborhood, interleaved across entities by rank position.
        var ownIdx = entities.map { _ in 1 }       // own chunk 0 spent in pass 1
        var neighIdx = entities.map { _ in 0 }
        var progressed = true
        while remaining > 0 && progressed {
            progressed = false
            for (i, e) in entities.enumerated() {
                guard remaining > 0 else { break }
                // Never enrich an entity that didn't get its primary slice — a must-have for
                // one entity outranks any nice-to-have for another.
                guard headerEmitted.contains(e.path) else { continue }
                if ownIdx[i] < e.ownChunks.count {
                    let ch = e.ownChunks[ownIdx[i]]
                    let label = ch.heading.map { "\(e.title) › \($0)" } ?? e.title
                    if tryEmit(title: e.title, path: e.path, label: label, snippet: ch.text) { progressed = true }
                    ownIdx[i] += 1
                } else if neighIdx[i] < e.neighborChunks.count {
                    let n = e.neighborChunks[neighIdx[i]]
                    if tryEmit(title: e.title, path: e.path,
                               label: "\(e.title) ✕ \(n.neighborTitle)", snippet: n.chunk.text) { progressed = true }
                    neighIdx[i] += 1
                }
            }
        }
        return out
    }
}
