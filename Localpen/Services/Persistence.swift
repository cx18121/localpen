import Foundation
import GRDB
import os

// GRDB stack + migrations per SWIFTUI-SPEC.md §11 / ADR 0006.
final class Persistence {
    let dbQueue: DatabaseQueue
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Persistence")

    init() throws {
        let dbPath = try Self.databasePath()
        let queue = try DatabaseQueue(path: dbPath.path)
        try Self.migrate(queue)
        self.dbQueue = queue
        log.info("Persistence ready at \(dbPath.path, privacy: .public)")
    }

    func save(_ interaction: Interaction) async {
        var copy = interaction
        do {
            try await dbQueue.write { db in
                try copy.insert(db)
            }
        } catch {
            log.error("save failed: \(error.localizedDescription)")
        }
    }

    func deleteAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM interactions")
        }
    }

    func count() async -> Int {
        (try? await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM interactions") ?? 0
        }) ?? 0
    }

    private static func databasePath() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Localpen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.create_interactions") { db in
            try db.create(table: "interactions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .integer).notNull()
                t.column("source_app", .text)
                t.column("selection", .text)
                t.column("action", .text).notNull()
                t.column("custom_prompt", .text)
                t.column("model_id", .text).notNull()
                t.column("model_output", .text)
                t.column("accepted", .integer).notNull()
                t.column("edited_output", .text)
            }
        }
        try migrator.migrate(queue)
    }
}
