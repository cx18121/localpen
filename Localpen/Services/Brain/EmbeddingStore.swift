import Foundation
import GRDB

/// Read/write cxkb-page vectors in `brain.sqlite` (BLOB, no sqlite-vec). `loadAll`
/// pulls every vector into memory for brute-force cosine — fine at vault scale.
struct EmbeddingStore {
    let dbQueue: DatabaseQueue

    /// `mtime` is the page mtime this vector was computed from — stored so a later edit
    /// (which bumps `pages.mtime`) marks the vector stale for re-embedding.
    func upsert(path: String, vector: [Float], model: String, mtime: Double) async throws {
        let blob = VectorMath.data(from: vector)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO page_embeddings(path, vector, dim, model, mtime) VALUES(?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET vector=excluded.vector, dim=excluded.dim,
                    model=excluded.model, mtime=excluded.mtime
                """, arguments: [path, blob, vector.count, model, mtime])
        }
    }

    /// path → vector, for every embedded page. Caller holds this in memory for search.
    func loadAll() async throws -> [String: [Float]] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path, vector FROM page_embeddings").reduce(into: [:]) {
                $0[$1["path"] as String] = VectorMath.floats(from: $1["vector"] as Data)
            }
        }
    }

    /// Paths needing (re)embedding: never embedded, OR embedded against an older page
    /// mtime (the file changed since). Drives incremental + invalidating backfill.
    func staleOrUnembeddedPaths() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.path FROM pages p
                LEFT JOIN page_embeddings e ON e.path = p.path
                WHERE e.path IS NULL OR e.mtime <> p.mtime
                """)
        }
    }
}
