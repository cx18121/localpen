import Foundation
import GRDB

/// Caches the full page-vector map across asks, reloading only when `page_embeddings`
/// changes. Invalidation key is a cheap aggregate fingerprint (count + Σmtime) — every
/// (re)embed bumps a row's mtime, every add/remove bumps the count, so any change flips it.
/// Actor-isolated: safe under concurrent asks. Replaces the per-ask `EmbeddingStore.loadAll()`.
actor PageVectorCache {
    private let dbQueue: DatabaseQueue
    private let store: EmbeddingStore
    private var cached: (fp: String, map: [String: [Float]])?

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        self.store = EmbeddingStore(dbQueue: dbQueue)
    }

    func vectors() async -> [String: [Float]] {
        let fp = await fingerprint("page_embeddings", whereClause: nil)
        if let cached, cached.fp == fp { return cached.map }
        let map = (try? await store.loadAll()) ?? [:]
        cached = (fp, map)
        return map
    }

    private func fingerprint(_ table: String, whereClause: String?) async -> String {
        let sql = "SELECT COUNT(*) AS c, COALESCE(SUM(mtime), 0) AS s FROM \(table)"
            + (whereClause.map { " WHERE \($0)" } ?? "")
        return (try? await dbQueue.read { db -> String in
            let row = try Row.fetchOne(db, sql: sql)
            let c = (row?["c"] as Int?) ?? 0
            let s = (row?["s"] as Double?) ?? 0
            return "\(c):\(s)"
        }) ?? ""
    }
}

/// Caches the person+project candidate pages used by mention detection + the autocomplete
/// title list, reloading only when that set changes (count + Σmtime over the two types).
actor CandidatePagesCache {
    private let dbQueue: DatabaseQueue
    private var cached: (fp: String, pages: [KBPage])?

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func pages() async -> [KBPage] {
        let fp = await fingerprint()
        if let cached, cached.fp == fp { return cached.pages }
        let pages = (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE type IN ('person','project')")
                .map(KBPage.init(brainRow:))
        }) ?? []
        cached = (fp, pages)
        return pages
    }

    private func fingerprint() async -> String {
        (try? await dbQueue.read { db -> String in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(SUM(mtime), 0) AS s
                FROM pages WHERE type IN ('person','project')
                """)
            let c = (row?["c"] as Int?) ?? 0
            let s = (row?["s"] as Double?) ?? 0
            return "\(c):\(s)"
        }) ?? ""
    }
}
