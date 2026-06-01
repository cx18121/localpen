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
