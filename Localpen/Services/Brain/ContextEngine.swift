import Foundation

/// Assembles the per-ask knowledge context (ADR 0014): ALWAYS the `self/` pages + `now.md`,
/// then top-K query hits, de-duped and capped to a token budget. Knowledge-only — the
/// `calendar:` line is assembled by the existing ask path, so this never touches the
/// calendar source and the two stay orthogonal. Gated by `isBrainEnabled`: off ⇒ `.empty`
/// ⇒ no `knowledge` line ⇒ byte-identical to a brain-never-existed prompt.
///
/// `bundle(for:)` takes the ask *question* because relevance is query-dependent — so it
/// runs at stream time (when the question exists), not at capture (unlike calendar).
final class ContextEngine {
    private let search: KBSearch
    private let index: BrainIndex
    private let config: BrainConfig
    private let isBrainEnabled: @Sendable () -> Bool
    /// Optional dense-retrieval client. `nil` (or a down server / unembedded vault) ⇒
    /// BM25-only, byte-identical to before hybrid existed.
    private let embeddingService: EmbeddingService?

    init(search: KBSearch, index: BrainIndex, config: BrainConfig = .default,
         embeddingService: EmbeddingService? = nil,
         isBrainEnabled: @escaping @Sendable () -> Bool = { BrainAccess.isActive }) {
        self.search = search
        self.index = index
        self.config = config
        self.embeddingService = embeddingService
        self.isBrainEnabled = isBrainEnabled
    }

    func bundle(for query: String) async -> ContextBundle {
        guard isBrainEnabled() else { return .empty }

        // self/ + now.md first (so identity always claims the budget), then query hits.
        var picked: [(page: KBPage, reason: ContextBundle.Provenance.Reason)] = []
        var used = Set<String>()
        for page in await index.alwaysPages(areas: config.alwaysIncludeAreas, files: config.alwaysIncludeFiles)
        where used.insert(page.path).inserted {
            picked.append((page, .always))
        }
        for hit in await queryHits(for: query)
        where used.insert(hit.page.path).inserted {
            picked.append((hit.page, .query))
        }

        var lines: [String] = []
        var sources: [ContextBundle.Provenance] = []
        var budget = config.maxContextTokens
        for (page, reason) in picked {
            let snippet = Self.condense(page.body, charCap: config.perPageCharCap)
            guard !snippet.isEmpty else { continue }
            let cost = Self.approxTokens(snippet)
            if cost > budget { break }   // hard stop — self/ already prioritized; no partial pages
            lines.append("kb [\(page.title)]: \(snippet)")
            sources.append(.init(title: page.title, path: page.path, reason: reason))
            budget -= cost
        }
        return ContextBundle(text: lines.joined(separator: "\n"), sources: sources,
                             approxTokens: config.maxContextTokens - budget)
    }

    /// Top-K query hits for the ask. Hybrid (BM25 ⊕ dense RRF) when an embedding service
    /// is configured AND the vault has vectors AND the query embeds; otherwise BM25-only.
    /// A down embedding server, an unembedded vault, or no service is a silent, correct
    /// fallback — never an error in the ask path.
    private func queryHits(for query: String) async -> [KBHit] {
        guard let embeddingService else { return await search.search(query, limit: config.topK) }
        let store = EmbeddingStore(dbQueue: index.dbQueue)
        guard let vectors = try? await store.loadAll(), !vectors.isEmpty,
              let queryVector = try? await embeddingService.embed(query, kind: .query) else {
            return await search.search(query, limit: config.topK)
        }
        return await search.hybridSearch(query, queryVector: queryVector,
                                         vectors: vectors, limit: config.topK)
    }

    /// Strip heading markers, collapse blank lines/runs to single spaces, head-cap with `…`.
    /// Pure. Keeps the informative lead of a page rather than raw-slicing mid-markdown.
    static func condense(_ body: String, charCap: Int) -> String {
        let cleaned = body
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { line -> String in
                var l = Substring(line)
                while l.first == "#" || l.first == ">" { l = l.dropFirst() }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleaned.count > charCap else { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: charCap)
        return cleaned[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }

    static func approxTokens(_ s: String) -> Int { max(1, s.count / 4) }
}
