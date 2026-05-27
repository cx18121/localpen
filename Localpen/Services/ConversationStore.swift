import Foundation
import GRDB

/// Resume metadata for the history list.
struct ThreadSummary: Equatable {
    let id: Int64
    let title: String
    let updatedAt: Int64   // epoch milliseconds
}

/// Thread persistence over the shared GRDB queue. A thread's turns are stored as
/// `interactions` rows (one per user→assistant exchange) tagged with `thread_id`;
/// `loadTurns` expands each row back into a user turn + an assistant turn.
final class ConversationStore {
    private let dbQueue: DatabaseQueue
    private let now: () -> Int64

    /// `now` returns epoch MILLISECONDS (injectable for deterministic tests).
    /// Millisecond resolution so threads touched seconds apart — or in the same
    /// second — order reliably.
    init(dbQueue: DatabaseQueue, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.dbQueue = dbQueue
        self.now = now
    }

    /// Inserts a threads row; returns its id. Title is a trimmed selection snippet.
    func createThread(originalSelection: Selection) async throws -> Int64 {
        let now = self.now()
        let title = Self.title(from: originalSelection.text)
        return try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO threads (created_at, updated_at, source_app, original_selection, title)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [now, now, originalSelection.sourceBundleID, originalSelection.text, title])
            return db.lastInsertedRowID
        }
    }

    /// Persists one user→assistant exchange as an interactions row.
    func appendExchange(threadID: Int64, userText: String, action: Action?,
                        modelID: String, assistantText: String) async throws {
        let now = self.now()
        var row = Interaction(
            id: nil, timestamp: now,
            sourceApp: nil,
            selection: nil,
            action: action?.rawValue ?? "custom",
            customPrompt: userText,
            modelID: modelID,
            modelOutput: assistantText,
            accepted: false,
            editedOutput: nil,
            threadID: threadID
        )
        try await dbQueue.write { db in
            try row.insert(db)
            try db.execute(sql: "UPDATE threads SET updated_at = ? WHERE id = ?",
                           arguments: [now, threadID])
        }
    }

    func touchThread(threadID: Int64) async throws {
        let now = self.now()
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE threads SET updated_at = ? WHERE id = ?",
                           arguments: [now, threadID])
        }
    }

    func recentThreads(limit: Int) async throws -> [ThreadSummary] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, updated_at FROM threads ORDER BY updated_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map {
                ThreadSummary(id: $0["id"], title: $0["title"] ?? "", updatedAt: $0["updated_at"])
            }
        }
    }

    /// Loads a thread's stored context (for resume). Returns nil if the thread is gone.
    func loadThread(id: Int64) async throws -> Selection? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT original_selection, source_app FROM threads WHERE id = ?
                """, arguments: [id]) else { return nil }
            let text: String = row["original_selection"] ?? ""
            let app: String? = row["source_app"]
            return Selection(text: text, sourceBundleID: app, sourceAppName: nil)
        }
    }

    /// Expands each stored exchange row into [user turn, assistant turn].
    func loadTurns(threadID: Int64) async throws -> [ConversationTurn] {
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, custom_prompt, model_output FROM interactions
                WHERE thread_id = ? ORDER BY timestamp ASC, id ASC
                """, arguments: [threadID])
        }
        var turns: [ConversationTurn] = []
        for (idx, row) in rows.enumerated() {
            let rawAction: String = row["action"] ?? "custom"
            let steer: String? = row["custom_prompt"]
            let model: String = row["model_output"] ?? ""
            if idx == 0 {
                let action = Action.reconstruct(rawValue: rawAction, steer: steer)
                turns.append(ConversationTurn(role: .user, text: action.pillLabel, action: action))
            } else {
                turns.append(ConversationTurn(role: .user, text: steer ?? ""))
            }
            turns.append(ConversationTurn(role: .assistant, text: model))
        }
        return turns
    }

    private static func title(from selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }
}
