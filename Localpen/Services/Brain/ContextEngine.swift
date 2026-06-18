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
    private let embeddingService: (any QueryEmbedder)?
    private let vectorCache: PageVectorCache
    private let candidates: CandidatePagesCache

    init(search: KBSearch, index: BrainIndex, config: BrainConfig = .default,
         embeddingService: (any QueryEmbedder)? = nil,
         isBrainEnabled: @escaping @Sendable () -> Bool = { BrainAccess.isActive }) {
        self.search = search
        self.index = index
        self.config = config
        self.embeddingService = embeddingService
        self.isBrainEnabled = isBrainEnabled
        self.vectorCache = PageVectorCache(dbQueue: index.dbQueue)
        self.candidates = CandidatePagesCache(dbQueue: index.dbQueue)
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

        // Embed the query once; share it across the mention layer and the generic layer.
        var queryVector: [Float]? = nil
        if let embeddingService { queryVector = try? await embeddingService.embed(query, kind: .query) }

        // W2: ground the named people/projects before generic query hits, so an entity the
        // user named never gets crowded out. nil ⇒ auto-detect from the query (Plan B passes a
        // user-confirmed list).
        let resolved: [DetectedMention]
        if let mentions { resolved = mentions } else { resolved = await detectMentions(in: query) }
        await groundMentions(resolved, query: query, queryVector: queryVector,
                             used: &used, budget: &budget, lines: &lines, sources: &sources)

        // Generic layer: passage-level retrieval + 1-hop graph expansion (W3).
        await fillGenericPassages(query: query, queryVector: queryVector,
                                  used: &used, budget: &budget, lines: &lines, sources: &sources)

        return ContextBundle(text: lines.joined(separator: "\n"), sources: sources,
                             approxTokens: config.maxContextTokens - budget)
    }

    /// People + project page titles, for the `[[`/`@` autocomplete (W2). Brain off ⇒ [].
    func candidateTitles() async -> [String] {
        guard isBrainEnabled() else { return [] }
        return await candidates.pages().map(\.title)
    }

    /// Detect mentions from the brain's people/project pages. Used internally by `bundle` when
    /// the caller passes no explicit set, and by the UI (Plan B) to show a pre-generation chip
    /// row. Brain off ⇒ no candidates ⇒ []. Order: explicit before auto (MentionResolver).
    func detectMentions(in query: String) async -> [DetectedMention] {
        guard isBrainEnabled() else { return [] }
        let candidatePages = await candidates.pages()
        return MentionResolver.detect(instruction: query, selection: nil, candidates: candidatePages).mentions
    }

    /// Ground each resolved mention: a header line + cosine-ranked chunks of the entity page,
    /// explicit before auto. Degrades to a condensed page snippet when chunks/embeddings are
    /// unavailable, so an explicit mention is never silently dropped.
    private func groundMentions(_ mentions: [DetectedMention], query: String, queryVector: [Float]?,
                                used: inout Set<String>,
                                budget: inout Int, lines: inout [String], sources: inout [ContextBundle.Provenance]) async {
        let ordered = mentions.sorted { ($0.origin == .explicit ? 0 : 1) < ($1.origin == .explicit ? 0 : 1) }
        guard !ordered.isEmpty else { return }

        let chunkStore = ChunkStore(dbQueue: index.dbQueue)
        // (no embed here anymore — use the passed-in queryVector)

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

    /// Generic ask layer (W3): chunk-level retrieval over the hybrid candidate pages plus the
    /// 1-hop link-neighbors (inbound + outbound) of the top hits, ranked against the query and
    /// packed per-page-capped into the remaining budget. No query vector / no embeddings ⇒
    /// today's page-level BM25 emit (byte-identical fallback).
    private func fillGenericPassages(query: String, queryVector: [Float]?, used: inout Set<String>,
                                     budget: inout Int, lines: inout [String],
                                     sources: inout [ContextBundle.Provenance]) async {
        // Fallback: no service / no query vector / unembedded vault → page-level BM25 (unchanged).
        guard embeddingService != nil, let qv = queryVector else {
            await fillGenericPagesBM25(query: query, used: &used, budget: &budget, lines: &lines, sources: &sources)
            return
        }
        let vectors = await vectorCache.vectors()
        guard !vectors.isEmpty else {
            await fillGenericPagesBM25(query: query, used: &used, budget: &budget, lines: &lines, sources: &sources)
            return
        }

        // 1. Candidate pages (hybrid), wider net than topK since chunk ranking trims it.
        let candidatePages = await search.hybridSearch(query, queryVector: qv,
                                                       vectors: vectors, limit: config.kCandidatePages)
        var titleByPath = Dictionary(candidatePages.map { ($0.page.path, $0.page.title) },
                                     uniquingKeysWith: { a, _ in a })

        // 2. 1-hop graph expansion from the top seeds (inbound + outbound), relevance-gated later.
        // linkedPaths tracks every neighbor of a top hit — whether or not it was already a hybrid
        // candidate — so provenance stays honest (the graph connection is real regardless).
        var linkedPaths = Set<String>()
        for hit in candidatePages.prefix(config.graphSeedCount) {
            let neighbors = await index.backlinks(toTitle: hit.page.title)
                          + index.outboundLinks(fromPath: hit.page.path)
            for n in neighbors where !used.contains(n.path) {
                if titleByPath[n.path] == nil { titleByPath[n.path] = n.title }
                linkedPaths.insert(n.path)
            }
        }

        // 3. Candidate paths = hybrid pages + neighbors, minus what the always/mention layers used.
        let candidatePaths = titleByPath.keys.filter { !used.contains($0) }
        guard !candidatePaths.isEmpty,
              let chunks = try? await ChunkStore(dbQueue: index.dbQueue).loadChunks(forPaths: Array(candidatePaths)),
              !chunks.isEmpty else {
            await fillGenericPagesBM25(query: query, used: &used, budget: &budget, lines: &lines, sources: &sources)
            return
        }

        // 4. Rank ALL candidate chunks against the query; 5. per-page-capped budget fill.
        let ranked = MentionGrounding.rankChunks(chunks, queryVector: qv, limit: chunks.count)
        for pick in PassageSelection.fill(ranked: ranked, titleByPath: titleByPath,
                                          linkedPaths: linkedPaths, budget: budget,
                                          perPageCap: config.perPageChunkCap) {
            lines.append(pick.line)
            sources.append(.init(title: pick.title, path: pick.path, reason: pick.isLinked ? .linked : .query))
            budget -= pick.tokens
            used.insert(pick.path)
        }
    }

    /// Page-level BM25 emit — the pre-W3 generic path, kept as the no-embeddings fallback.
    private func fillGenericPagesBM25(query: String, used: inout Set<String>, budget: inout Int,
                                      lines: inout [String], sources: inout [ContextBundle.Provenance]) async {
        for hit in await search.search(query, limit: config.topK) where used.insert(hit.page.path).inserted {
            let snippet = Self.condense(hit.page.body, charCap: config.perPageCharCap)
            guard !snippet.isEmpty else { continue }
            let cost = Self.approxTokens(snippet)
            guard cost <= budget else { continue }
            lines.append("kb [\(hit.page.title)]: \(snippet)")
            sources.append(.init(title: hit.page.title, path: hit.page.path, reason: .query))
            budget -= cost
        }
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
