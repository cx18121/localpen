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

    func bundle(for query: String, mentions: [DetectedMention]? = nil) async -> ContextBundle {
        guard isBrainEnabled() else { return .empty }

        var used = Set<String>()
        var lines: [String] = []
        var sources: [ContextBundle.Provenance] = []
        var budget = config.maxContextTokens

        func emit(_ snippet: String, page: KBPage, reason: ContextBundle.Provenance.Reason, label: String? = nil) {
            guard !snippet.isEmpty else { return }
            let cost = Self.approxTokens(snippet)
            guard cost <= budget else { return }
            lines.append("kb [\(label ?? page.title)]: \(snippet)")
            sources.append(.init(title: page.title, path: page.path, reason: reason))
            budget -= cost
        }

        // self/ + now.md first (identity always claims the budget).
        for page in await index.alwaysPages(areas: config.alwaysIncludeAreas, files: config.alwaysIncludeFiles)
        where used.insert(page.path).inserted {
            emit(Self.condense(page.body, charCap: config.perPageCharCap), page: page, reason: .always)
        }

        // W2: ground the named people/projects before generic query hits, so an entity the
        // user named never gets crowded out. nil ⇒ auto-detect from the query (Plan B passes a
        // user-confirmed list).
        let resolved: [DetectedMention]
        if let mentions { resolved = mentions } else { resolved = await autoDetect(in: query) }
        await groundMentions(resolved, query: query, used: &used, budget: &budget, lines: &lines, sources: &sources)

        // Generic query hits fill whatever budget remains.
        for hit in await queryHits(for: query) where used.insert(hit.page.path).inserted {
            emit(Self.condense(hit.page.body, charCap: config.perPageCharCap), page: hit.page, reason: .query)
        }

        return ContextBundle(text: lines.joined(separator: "\n"), sources: sources,
                             approxTokens: config.maxContextTokens - budget)
    }

    /// Detect mentions from the brain's people/project pages when the caller didn't pass an
    /// explicit (user-confirmed) set. Plan B passes a confirmed list and skips this.
    private func autoDetect(in query: String) async -> [DetectedMention] {
        let candidates = await index.pages(ofType: .person) + index.pages(ofType: .project)
        return MentionResolver.detect(instruction: query, selection: nil, candidates: candidates).mentions
    }

    /// Ground each resolved mention: a header line + cosine-ranked chunks of the entity page,
    /// explicit before auto. Degrades to a condensed page snippet when chunks/embeddings are
    /// unavailable, so an explicit mention is never silently dropped.
    private func groundMentions(_ mentions: [DetectedMention], query: String, used: inout Set<String>,
                                budget: inout Int, lines: inout [String], sources: inout [ContextBundle.Provenance]) async {
        let ordered = mentions.sorted { ($0.origin == .explicit ? 0 : 1) < ($1.origin == .explicit ? 0 : 1) }
        guard !ordered.isEmpty else { return }

        let chunkStore = ChunkStore(dbQueue: index.dbQueue)
        var queryVector: [Float]? = nil
        if let embeddingService {
            queryVector = try? await embeddingService.embed(query, kind: .query)
        }

        // Build each entity's grounding material (header + ranked own chunks + ranked backlink
        // neighborhood), deduping pages against what's already in the bundle, then let
        // MentionGrounding.assemble pack it into the budget primary-slice-first.
        var entities: [MentionGrounding.EntityContent] = []
        var seen = used   // dedup entity + neighbor pages against always-pages and each other
        for m in ordered {
            guard let page = await index.pageByTitle(m.title), !seen.contains(page.path) else { continue }
            seen.insert(page.path)
            let header: String? = page.type == .person
                ? MentionGrounding.personHeader(PeopleInsights.person(from: page, today: Date()))
                : MentionGrounding.projectHeader(page)

            var ownChunks: [ChunkStore.ChunkRow] = []
            var neighborChunks: [MentionGrounding.NeighborChunk] = []
            if let qv = queryVector {
                if let chunks = try? await chunkStore.loadChunks(forPaths: [page.path]), !chunks.isEmpty {
                    ownChunks = MentionGrounding.rankChunks(chunks, queryVector: qv, limit: 3)
                }
                // Neighborhood: pages that link TO this entity (meetings/projects it appears in).
                let neighbors = await index.backlinks(toTitle: page.title)
                let titleByPath = Dictionary(neighbors.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
                let neighborPaths = Array(neighbors.map(\.path).filter { !seen.contains($0) }.prefix(8))
                if !neighborPaths.isEmpty,
                   let nChunks = try? await chunkStore.loadChunks(forPaths: neighborPaths), !nChunks.isEmpty {
                    neighborChunks = MentionGrounding.rankChunks(nChunks, queryVector: qv, limit: 3).map {
                        .init(neighborTitle: titleByPath[$0.path] ?? "", chunk: $0)
                    }
                    neighborPaths.forEach { seen.insert($0) }
                }
            }
            // Degradation (or empty embeddings): a single condensed-body pseudo-chunk so
            // assemble still emits the header + page head. An explicit mention is never dropped.
            if ownChunks.isEmpty {
                let condensed = Self.condense(page.body, charCap: config.perPageCharCap)
                if !condensed.isEmpty {
                    ownChunks = [ChunkStore.ChunkRow(path: page.path, index: 0, heading: nil, text: condensed, vector: [])]
                }
            }
            entities.append(.init(title: page.title, path: page.path, header: header,
                                  ownChunks: ownChunks, neighborChunks: neighborChunks))
        }

        for g in MentionGrounding.assemble(entities, budget: budget) {
            lines.append(g.text)
            sources.append(.init(title: g.title, path: g.path, reason: .mention))
            budget -= g.tokens
            used.insert(g.path)
        }
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
