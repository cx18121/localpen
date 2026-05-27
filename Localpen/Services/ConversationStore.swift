import Foundation
import GRDB
import os

/// Resume metadata for the history list.
struct ThreadSummary: Equatable {
    let id: Int64
    let title: String
    let updatedAt: Int64
}

/// Thread persistence over the shared GRDB queue. A thread's turns are stored as
/// `interactions` rows (one per user→assistant exchange) tagged with `thread_id`;
/// `loadTurns` expands each row back into a user turn + an assistant turn.
final class ConversationStore {
    private let dbQueue: DatabaseQueue
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ConversationStore")

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// Inserts a threads row; returns its id. Title is a trimmed selection snippet.
    func createThread(originalSelection: Selection) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
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
        let now = Int64(Date().timeIntervalSince1970)
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
        let now = Int64(Date().timeIntervalSince1970)
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE threads SET updated_at = ? WHERE id = ?",
                           arguments: [now, threadID])
        }
    }

    func recentThreads(limit: Int) async throws -> [ThreadSummary] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, updated_at FROM threads ORDER BY updated_at DESC LIMIT ?
                """, arguments: [limit]).map {
                ThreadSummary(id: $0["id"], title: $0["title"] ?? "", updatedAt: $0["updated_at"])
            }
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
