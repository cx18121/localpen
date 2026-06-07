import Foundation
import GRDB

/// Read/write cxkb-page vectors in `brain.sqlite` (BLOB, no sqlite-vec). `loadAll`
/// pulls every vector into memory for brute-force cosine — fine at vault scale.
struct EmbeddingStore {
    let dbQueue: DatabaseQueue

    func upsert(path: String, vector: [Float], model: String) async throws {
        let blob = VectorMath.data(from: vector)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO page_embeddings(path, vector, dim, model) VALUES(?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET vector=excluded.vector, dim=excluded.dim, model=excluded.model
                """, arguments: [path, blob, vector.count, model])
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

    /// Paths that have no embedding yet (drives incremental backfill).
    func unembeddedPaths() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.path FROM pages p
                LEFT JOIN page_embeddings e ON e.path = p.path
                WHERE e.path IS NULL
                """)
        }
    }
}
