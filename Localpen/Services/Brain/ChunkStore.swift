import Foundation
import GRDB

/// Read/write chunk-level vectors in `brain.sqlite` (`page_chunks`, ADR 0014 extension for
/// W2). Mirrors `EmbeddingStore` but per-chunk and scoped: `loadChunks(forPaths:)` pulls only
/// the handful of pages a mention touches, never the whole vault. Vectors are BLOBs (no
/// sqlite-vec); cosine is brute-force at the scoped count.
struct ChunkStore {
    let dbQueue: DatabaseQueue

    struct Insert: Equatable { let index: Int; let heading: String?; let text: String; let vector: [Float] }
    struct ChunkRow: Equatable { let path: String; let index: Int; let heading: String?; let text: String; let vector: [Float] }

    func replace(path: String, chunks: [Insert], model: String, mtime: Double) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_chunks WHERE path = ?", arguments: [path])
            for c in chunks {
                try db.execute(sql: """
                    INSERT INTO page_chunks(path, chunk_index, heading, text, vector, dim, model, mtime)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, arguments: [path, c.index, c.heading, c.text,
                                     VectorMath.data(from: c.vector), c.vector.count, model, mtime])
            }
        }
    }

    func loadChunks(forPaths paths: [String]) async throws -> [ChunkRow] {
        guard !paths.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let qs = paths.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT path, chunk_index, heading, text, vector FROM page_chunks
                WHERE path IN (\(qs)) ORDER BY path, chunk_index
                """, arguments: StatementArguments(paths)).map { row in
                ChunkRow(path: row["path"], index: row["chunk_index"], heading: row["heading"],
                         text: row["text"], vector: VectorMath.floats(from: row["vector"] as Data))
            }
        }
    }

    func staleOrUnchunkedPaths() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.path FROM pages p
                LEFT JOIN page_chunks c ON c.path = p.path
                GROUP BY p.path
                HAVING COUNT(c.path) = 0 OR MAX(c.mtime) <> p.mtime
                """)
        }
    }
}
