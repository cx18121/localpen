import Foundation
import GRDB

/// One ranked search result.
struct KBHit: Sendable, Equatable { let page: KBPage; let score: Double }

/// FTS5 bm25 relevance + a log-scaled backlink boost (ADR 0014). `score` is the single
/// pure seam embeddings later extend (add a `semantic` term; nothing else changes).
final class KBSearch {
    private let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// Top-`limit` pages for a free-text query. bm25 weights title 4× / tags 2× / body 1×
    /// (a query that IS a page's title beats a passing body mention); the backlink boost
    /// re-ranks only among FTS matches (a popular page never surfaces on relevance 0).
    func search(_ query: String, limit: Int) async -> [KBHit] {
        let match = Self.sanitizeMatch(query)
        guard !match.isEmpty else { return [] }
        let rows: [Row] = (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.path, p.title, p.type, p.area, p.body, p.tags, p.mtime, p.frontmatter_json,
                       bm25(pages_fts, 4.0, 1.0, 2.0) AS bm,
                       COALESCE(b.indegree, 0) AS indeg
                FROM pages_fts
                JOIN pages p ON p.rowid = pages_fts.rowid
                LEFT JOIN backlinks b ON b.title = p.title COLLATE NOCASE
                WHERE pages_fts MATCH ?
                """, arguments: [match])
        }) ?? []
        let hits = rows.map { row in
            KBHit(page: KBPage(brainRow: row),
                  score: Self.score(bm: row["bm"], indegree: row["indeg"]))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Hybrid retrieval: fuse the BM25 ranking with a dense cosine ranking via RRF.
    /// `vectors` is the in-memory path→vector map (EmbeddingStore.loadAll); `queryVector`
    /// is the embedded query. If `vectors` is empty this degrades to BM25-only.
    func hybridSearch(_ query: String, queryVector: [Float],
                      vectors: [String: [Float]], limit: Int) async -> [KBHit] {
        // 1. BM25 ranked paths (reuse existing FTS path; take a generous candidate depth).
        let bmHits = await search(query, limit: 50)
        let bmRanked = bmHits.map(\.page.path)

        // 2. Dense ranked paths by cosine to the query vector.
        let denseRanked = vectors
            .map { (path: $0.key, sim: VectorMath.cosine(queryVector, $0.value)) }
            .sorted { $0.sim > $1.sim }
            .prefix(50)
            .map(\.path)

        // 3. RRF fuse; if there are no vectors, RRF over [bmRanked] == BM25 order.
        let fused = RankFusion.rrf([bmRanked, Array(denseRanked)], k: 60)

        // 4. Re-hydrate KBPage for the fused top-`limit` (load from pages by path).
        let top = Array(fused.prefix(limit))
        let pages: [String: KBPage] = (try? await dbQueue.read { db -> [String: KBPage] in
            guard !top.isEmpty else { return [:] }
            let qs = top.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE path IN (\(qs))",
                                    arguments: StatementArguments(top))
                .reduce(into: [:]) { $0[$1["path"] as String] = KBPage(brainRow: $1) }
        }) ?? [:]
        // Preserve fused order; score is the reciprocal-rank position (descending).
        return top.enumerated().compactMap { idx, path in
            pages[path].map { KBHit(page: $0, score: 1.0 / Double(idx + 1)) }
        }
    }

    /// Pure ranking. bm25 is negative-better, so negate; the additive log boost means a
    /// hub with 40 backlinks doesn't swamp a tightly-relevant page with 2.
    static func score(bm: Double, indegree: Int) -> Double {
        -bm + 0.5 * log2(1 + Double(indegree))
    }

    /// FTS5 MATCH-safe expression: word tokens only, each quoted, OR-joined — so
    /// punctuation in an ask question can't throw a syntax error.
    static func sanitizeMatch(_ query: String) -> String {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
