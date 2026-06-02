import Foundation
import GRDB
import os

extension Notification.Name {
    /// Posted after a durable user-authored row commits, on either persistence path
    /// (one-shot Persistence.save OR ConversationStore.{createThreadWithSeed,
    /// appendExchange}). MemoryService subscribes; tests assert one post per write.
    static let interactionPersisted = Notification.Name("localpen.interactionPersisted")
}

// GRDB stack + migrations per SWIFTUI-SPEC.md §11 / ADR 0006.
final class Persistence {
    let dbQueue: DatabaseQueue
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Persistence")

    init() throws {
        let dbPath = Self.databasePath()
        let queue = try DatabaseQueue(path: dbPath.path)
        try Self.migrate(queue)
        self.dbQueue = queue
        log.info("Persistence ready at \(dbPath.path, privacy: .public)")
    }

    /// Test-only constructor that uses an in-memory GRDB queue, so tests don't touch
    /// Application Support and don't bleed state between cases.
    init(testInMemory: Bool) throws {
        precondition(testInMemory)
        let queue = try DatabaseQueue()
        try Self.migrate(queue)
        self.dbQueue = queue
        log.info("Persistence ready (in-memory test mode)")
    }

    func save(_ interaction: Interaction) async {
        var copy = interaction
        do {
            try await dbQueue.write { db in
                try copy.insert(db)
            }
            NotificationCenter.default.post(name: .interactionPersisted, object: nil)
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

    /// JSON export of interactions that survive the Forget tombstone. Rows older
    /// than `style_profile.forgotten_before` are excluded so Forgotten history
    /// never leaks through the export — the export is the data-portability path,
    /// and Forget must be durable across it (the privacy bug was a plain
    /// `SELECT * FROM interactions` that ignored the tombstone). Conversation
    /// turns are interaction rows too, so this also covers thread history.
    func exportInteractionsJSON() async -> String {
        (try? await dbQueue.read { db -> String in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM interactions
                WHERE timestamp >= (SELECT forgotten_before FROM style_profile WHERE id = 1)
                ORDER BY id
                """)
            let dicts: [[String: Any]] = rows.map { row in
                var d: [String: Any] = [:]
                for col in row.columnNames where row[col] != nil { d[col] = row[col] }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        }) ?? "[]"
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

    private static func databasePath() -> URL {
        AppSupport.root().appendingPathComponent("history.sqlite")
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

        // v5: Calendar context (ADR 0012). Stored on the THREAD, parallel to
        // source_app, so a resumed ask thread replays the exact prompt the model
        // saw. Deliberately NOT on the interactions row — keeps calendar text out
        // of the interactions export + memory inference. Nullable: writing threads
        // and pre-v5 ask threads leave it NULL (no calendar line on resume).
        migrator.registerMigration("v5.thread_context_calendar") { db in
            try db.alter(table: "threads") { t in
                t.add(column: "context_calendar", .text)
            }
        }

        // v6: Knowledge context (ADR 0014). Stored on the THREAD, exactly like
        // context_calendar — so the assembled KB text replays on resume but stays out
        // of the interactions export + MemoryAttribution voice/facts inference.
        // Nullable: writing threads and pre-v6 ask threads leave it NULL.
        migrator.registerMigration("v6.thread_context_knowledge") { db in
            try db.alter(table: "threads") { t in
                t.add(column: "context_knowledge", .text)
            }
        }

        // v7: Answer provenance — the KB pages a brain-backed ask drew on, stored as a
        // JSON array on the THREAD (like context_knowledge) so the source chips replay on
        // resume. Nullable: non-brain / pre-v7 ask threads leave it NULL.
        migrator.registerMigration("v7.thread_context_provenance") { db in
            try db.alter(table: "threads") { t in
                t.add(column: "context_provenance", .text)
            }
        }

        // v8: Generalized capture-time context sources (ADR 0019) — a JSON array of
        // ContextItem on the THREAD (like context_calendar, which it folds forward), so a
        // resumed ask replays its file/calendar/… chips. Nullable: pre-v8 ask threads leave
        // it NULL and fall back to the legacy `context_calendar` column on load.
        migrator.registerMigration("v8.thread_context_sources") { db in
            try db.alter(table: "threads") { t in
                t.add(column: "context_sources", .text)
            }
        }
        try migrator.migrate(queue)
    }
}
