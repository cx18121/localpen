import Foundation
import GRDB

/// One full-text search hit: the message (headers only) plus the matching snippet.
struct MailSearchHit: Sendable {
    let message: MailMessage
    let snippet: String
}

/// A small FTS5 index over recent inbox mail. Neither the Mail store nor Spotlight expose
/// searchable bodies (verified), so — like the brain does over notes — we build our own,
/// scoped to a recent window, lazily + incrementally. All methods are synchronous GRDB and
/// meant to be called off the main actor; the underlying `DatabaseQueue` is thread-safe.
final class MailSearchIndex: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init?() {
        let url = AppSupport.root().appendingPathComponent("mail-search.sqlite")
        guard let q = try? DatabaseQueue(path: url.path), (try? Self.migrate(q)) != nil else { return nil }
        self.dbQueue = q
    }

    /// In-memory index for tests.
    init(testInMemory: Bool) throws {
        precondition(testInMemory)
        let q = try DatabaseQueue()
        try Self.migrate(q)
        self.dbQueue = q
    }

    private static func migrate(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
                    message_id UNINDEXED, sender, subject, body, date_received UNINDEXED,
                    tokenize = 'porter unicode61'
                )
                """)
            // Durable record of emails promoted to cxkb, so the same email can't be saved
            // twice (survives restarts; NOT touched by the FTS prune).
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS saved_cxkb (message_id TEXT PRIMARY KEY)")
        }
    }

    // MARK: Saved-to-cxkb dedup

    func markSaved(_ id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO saved_cxkb (message_id) VALUES (?)",
                           arguments: ["\(id)"])
        }
    }

    func savedIDs() -> Set<Int64> {
        let rows = (try? dbQueue.read { try String.fetchAll($0, sql: "SELECT message_id FROM saved_cxkb") }) ?? []
        return Set(rows.compactMap(Int64.init))
    }

    var count: Int {
        (try? dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM mail_fts") ?? 0 }) ?? 0
    }

    /// Message ids already indexed — so a refresh only reads bodies for new mail.
    func indexedIDs() -> Set<Int64> {
        let rows = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT message_id FROM mail_fts")
        }) ?? []
        return Set(rows.compactMap(Int64.init))
    }

    /// Add messages (with bodies). Caller filters out already-indexed ids.
    func insert(_ messages: [MailMessage]) {
        try? dbQueue.write { db in
            for m in messages {
                try db.execute(sql: """
                    INSERT INTO mail_fts (message_id, sender, subject, body, date_received)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: ["\(m.id)", m.sender, m.subject, m.body ?? "",
                                     "\(m.date.timeIntervalSince1970)"])
            }
        }
    }

    /// Drop indexed messages that are no longer in the inbox window (archived/deleted, or
    /// aged out) so search doesn't surface mail you've since filed away.
    func remove(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        try? dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM mail_fts WHERE message_id = ?", arguments: ["\(id)"])
            }
        }
    }

    /// Full-text search across sender / subject / body, bm25-ranked, with a body snippet.
    func search(_ rawQuery: String, limit: Int) -> [MailSearchHit] {
        guard let match = Self.ftsQuery(rawQuery) else { return [] }
        let rows = (try? dbQueue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT message_id, sender, subject, date_received,
                       snippet(mail_fts, 3, '', '', '…', 14) AS snip
                FROM mail_fts
                WHERE mail_fts MATCH ?
                ORDER BY bm25(mail_fts, 0.0, 4.0, 8.0, 1.0, 0.0)
                LIMIT ?
                """, arguments: [match, limit])
        }) ?? []
        return rows.compactMap { row in
            guard let id = Int64(row["message_id"] as String? ?? "") else { return nil }
            let date = Double(row["date_received"] as String? ?? "") ?? 0
            let msg = MailMessage(id: id, sender: row["sender"] ?? "", subject: row["subject"] ?? "",
                                  date: Date(timeIntervalSince1970: date), body: nil)
            return MailSearchHit(message: msg, snippet: (row["snip"] as String? ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Turn free user text into a safe FTS5 MATCH expression: alphanumeric tokens, ANDed,
    /// with a prefix wildcard on the last token (so "conf" matches "confirmation" as you
    /// type). Returns nil when there's nothing searchable — never raw user text (which can
    /// throw on FTS5 syntax like quotes/operators).
    static func ftsQuery(_ raw: String) -> String? {
        // Tokens are alphanumeric-only (split on the inverse), so they're safe as FTS5
        // barewords — no quoting/escaping needed. Space = implicit AND; the last token gets
        // a prefix `*` so it matches as you type ("conf" → "confirmation").
        var tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        let last = tokens.removeLast()
        tokens.append(last + "*")
        return tokens.joined(separator: " ")
    }
}
