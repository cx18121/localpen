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
            try db.execute(sql: "DELETE FROM threads")
        }
    }

    func count() async -> Int {
        (try? await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM interactions") ?? 0
        }) ?? 0
    }

    func loadStyleProfile() async -> StyleProfile {
        (try? await dbQueue.read { db in
            try StyleProfile.fetchOne(db, key: 1)
        }) ?? StyleProfile()
    }

    func saveStyleProfile(_ profile: StyleProfile) async {
        var p = profile; p.id = 1
        do {
            try await dbQueue.write { db in
                try p.save(db)   // upsert: row 1 exists from the migration
            }
        } catch {
            log.error("saveStyleProfile failed: \(error.localizedDescription)")
        }
    }

    /// Durable forget: clears the card/facts AND sets the tombstone to `at`.
    /// `at` is unix epoch **milliseconds** — same unit as `interactions.timestamp`
    /// after migration v4. After this, exemplar selection and profile generation
    /// ignore rows with timestamp < at — so the next regeneration cannot rebuild
    /// from the same history.
    func forgetMemory(at: Int64) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE style_profile
                       SET voice_card = NULL,
                           facts = '[]',
                           generated_at = NULL,
                           sample_count = 0,
                           user_edited = 0,
                           forgotten_before = ?
                     WHERE id = 1
                    """, arguments: [at])
            }
        } catch {
            log.error("forgetMemory failed: \(error.localizedDescription)")
        }
    }

    /// Count of interactions whose timestamp is >= `since` (the forgotten_before tombstone
    /// or 0). The cold-start gate and the regeneration threshold both read this count, NOT
    /// raw `count()`, so forgotten history can never satisfy a threshold by itself.
    func eligibleInteractionCount(since: Int64) async -> Int {
        (try? await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM interactions WHERE timestamp >= ?",
                             arguments: [since]) ?? 0
        }) ?? 0
    }

    private static func databasePath() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Localpen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    static func migrate(_ queue: DatabaseQueue) throws {
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
        migrator.registerMigration("v2.threads") { db in
            try db.create(table: "threads") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()   // bumped by ConversationStore on each appended turn (Task 4)
                t.column("source_app", .text)
                t.column("original_selection", .text)
                t.column("title", .text)   // auto-generated snippet of the original selection; not user-editable
            }
            try db.alter(table: "interactions") { t in
                // Nullable FK; NULL = one-shot interaction. setNull on delete so
                // deleting a thread leaves its interaction rows as orphan one-shots
                // rather than dangling references.
                t.add(column: "thread_id", .integer).references("threads", onDelete: .setNull)
            }
        }
        migrator.registerMigration("v3.style_profile") { db in
            try db.create(table: "style_profile") { t in
                t.column("id", .integer).primaryKey()
                t.column("voice_card", .text)
                t.column("facts", .text).notNull().defaults(to: "[]")
                t.column("generated_at", .integer)
                t.column("sample_count", .integer).notNull().defaults(to: 0)
                t.column("user_edited", .integer).notNull().defaults(to: 0)
                t.column("forgotten_before", .integer).notNull().defaults(to: 0)
            }
            // Ensure the single row exists with defaults so callers can blind-upsert.
            try db.execute(sql: """
                INSERT OR IGNORE INTO style_profile (id, facts) VALUES (1, '[]')
                """)
        }

        // v4: Normalize legacy one-shot interaction timestamps from seconds to ms so all
        // memory queries (eligibility, forgotten_before tombstone, exemplar selection)
        // operate in a single time unit. Any value < 10_000_000_000 is plausibly seconds
        // (covers Unix-seconds-epoch through year 2286) and is multiplied by 1000.
        // Conversation rows already store ms (per ConversationStore.swift:21) so they
        // pass the guard unchanged.
        migrator.registerMigration("v4.normalize_interaction_timestamps_to_ms") { db in
            try db.execute(sql: """
                UPDATE interactions
                   SET timestamp = timestamp * 1000
                 WHERE timestamp < 10000000000
                """)
        }
        try migrator.migrate(queue)
    }
}
