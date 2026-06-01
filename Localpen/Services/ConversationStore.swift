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

    /// Atomically creates a thread AND its seed exchange in one transaction, so a
    /// partial write can never leave a thread whose first row isn't the seed (which
    /// would make `loadTurns` reconstruct the wrong seed action on resume). Returns
    /// the new thread id and the seed exchange's interaction id (so the seed
    /// assistant turn can later be marked accepted); throws (rolling back both
    /// inserts) on any failure.
    func createThreadWithSeed(originalSelection: Selection, seedUserText: String,
                              seedAction: Action, modelID: String,
                              assistantText: String) async throws -> (threadID: Int64, seedInteractionID: Int64) {
        let now = self.now()
        let title = Self.title(from: originalSelection.text)
        let result: (threadID: Int64, seedInteractionID: Int64) = try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO threads (created_at, updated_at, source_app, original_selection, title)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [now, now, originalSelection.sourceBundleID, originalSelection.text, title])
            let threadID = db.lastInsertedRowID
            var seed = Interaction(
                id: nil, timestamp: now, sourceApp: nil, selection: nil,
                action: seedAction.rawValue, customPrompt: seedUserText,
                modelID: modelID, modelOutput: assistantText,
                accepted: false, editedOutput: nil, threadID: threadID
            )
            try seed.insert(db)
            return (threadID, seed.id ?? db.lastInsertedRowID)
        }
        NotificationCenter.default.post(name: .interactionPersisted, object: nil)
        return result
    }

    /// Creates an ask-seeded thread. Unlike `createThreadWithSeed`, the
    /// caller-provided `question` is the title source AND the seed user
    /// text, because the primary no-selection ask flow has no selection at
    /// all. Persists the optional `contextSelection` on the seed Interaction
    /// row so `loadTurns` → `Action.reconstruct` can rehydrate the
    /// `withSelection` flag, and `loadSeedAskContext` can rebuild the chip
    /// state for `Conversation.messages` on resume.
    func createThreadForAsk(question: String,
                            contextSelection: String?,
                            sourceApp: String?,
                            contextCalendar: String? = nil,
                            contextKnowledge: String? = nil,
                            modelID: String,
                            assistantText: String) async throws -> (threadID: Int64, seedInteractionID: Int64) {
        let now = self.now()
        let title = Self.title(from: question)
        let result: (threadID: Int64, seedInteractionID: Int64) = try await dbQueue.write { db in
            // `context_calendar` / `context_knowledge` are stored on the THREAD (not the
            // seed Interaction), so that context text never enters the interactions export
            // or MemoryAttribution voice/facts inference (ADR 0012 / ADR 0014 privacy note).
            try db.execute(sql: """
                INSERT INTO threads (created_at, updated_at, source_app, original_selection, title, context_calendar, context_knowledge)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [now, now, sourceApp, question, title, contextCalendar, contextKnowledge])
            let threadID = db.lastInsertedRowID
            // `selection` carries the chip-attached selection (or nil) so
            // the withSelection flag rehydrates on resume.
            var seed = Interaction(
                id: nil, timestamp: now, sourceApp: sourceApp,
                selection: contextSelection,
                action: "ask",
                customPrompt: question,
                modelID: modelID, modelOutput: assistantText,
                accepted: false, editedOutput: nil, threadID: threadID
            )
            try seed.insert(db)
            return (threadID, seed.id ?? db.lastInsertedRowID)
        }
        NotificationCenter.default.post(name: .interactionPersisted, object: nil)
        return result
    }

    /// Persists one user→assistant exchange as an interactions row; returns its id
    /// (so the assistant turn can be marked accepted on acceptance).
    @discardableResult
    func appendExchange(threadID: Int64, userText: String, action: Action?,
                        modelID: String, assistantText: String) async throws -> Int64 {
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
        let rowID: Int64 = try await dbQueue.write { db in
            try row.insert(db)
            try db.execute(sql: "UPDATE threads SET updated_at = ? WHERE id = ?",
                           arguments: [now, threadID])
            return row.id ?? db.lastInsertedRowID
        }
        NotificationCenter.default.post(name: .interactionPersisted, object: nil)
        return rowID
    }

    /// Marks a persisted exchange accepted (the user applied/kept that assistant turn).
    func markAccepted(interactionID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE interactions SET accepted = 1 WHERE id = ?",
                           arguments: [interactionID])
        }
    }

    /// Removes a thread and all its interaction rows in one transaction. Used to
    /// compensate a promotion whose user navigated away before it committed (so a
    /// fast Back/Accept can't leave an abandoned resumable thread behind). Deletes
    /// the interactions explicitly rather than relying on the FK (which is SET NULL,
    /// and would otherwise orphan the rows as stray one-shots).
    func deleteThread(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM interactions WHERE thread_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [id])
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

    /// For an ask thread, returns the seed Interaction's chip context — the
    /// selection chip's text (if any) plus the source-app label persisted
    /// on the thread. Returns nil for non-ask threads. The persisted
    /// `original_selection` holds the question for title purposes
    /// (createThreadForAsk); the actual chip selection lives on the seed
    /// Interaction's `selection` column. Used by `Conversation.messages` on
    /// resume to rebuild the seed user message via `askUserMessage` —
    /// without this, the question would be wrapped as its own selection,
    /// corrupting the model boundary.
    func loadSeedAskContext(threadID: Int64) async throws -> AskContext? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT i.selection AS sel, t.source_app AS app, t.context_calendar AS cal, t.context_knowledge AS kb
                FROM interactions i
                JOIN threads t ON t.id = i.thread_id
                WHERE i.thread_id = ? AND i.action = 'ask'
                ORDER BY i.timestamp ASC, i.id ASC LIMIT 1
                """, arguments: [threadID]) else { return nil }
            let sel: String? = row["sel"]
            let app: String? = row["app"]
            let cal: String? = row["cal"]
            let kb: String? = row["kb"]
            return AskContext(appLabel: app, selection: sel, calendar: cal, knowledge: kb)
        }
    }

    /// Expands each stored exchange row into [user turn, assistant turn].
    func loadTurns(threadID: Int64) async throws -> [ConversationTurn] {
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, action, custom_prompt, model_output, selection FROM interactions
                WHERE thread_id = ? ORDER BY timestamp ASC, id ASC
                """, arguments: [threadID])
        }
        var turns: [ConversationTurn] = []
        for (idx, row) in rows.enumerated() {
            let interactionID: Int64 = row["id"]
            let rawAction: String = row["action"] ?? "custom"
            let steer: String? = row["custom_prompt"]
            let model: String = row["model_output"] ?? ""
            let selection: String? = row["selection"]
            if idx == 0 {
                // Pass selection so .ask rehydrates its withSelection flag.
                // Other actions ignore the parameter (additive signature).
                let action = Action.reconstruct(rawValue: rawAction, steer: steer, selection: selection)
                turns.append(ConversationTurn(role: .user, text: action.pillLabel, action: action))
            } else {
                turns.append(ConversationTurn(role: .user, text: steer ?? ""))
            }
            // Carry the row id on the assistant turn so accepting it can mark exactly
            // this exchange accepted.
            turns.append(ConversationTurn(role: .assistant, text: model, interactionID: interactionID))
        }
        return turns
    }

    private static func title(from selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }
}
