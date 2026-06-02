import Foundation

/// A snapshot of a conversation, captured instantly on the ask hot path (ADR 0015) so
/// the nightly dream cycle has something to synthesize — no model, no latency at capture
/// time. Codable so it round-trips to a JSON file on disk; `Sendable` value type.
struct StashedConversation: Codable, Equatable, Sendable {
    let threadID: Int64
    let isAsk: Bool
    let seedAction: String       // Action.rawValue of the seed turn
    let stampMillis: Int64       // capture time, ms since epoch (the codebase's ms invariant)
    let turns: [StashedTurn]
}

struct StashedTurn: Codable, Equatable, Sendable {
    let role: String             // "user" | "assistant"
    let text: String
}

/// The hot-path stash (ADR 0015). One JSON file per thread under a Localpen-private
/// directory — NOT inside the vault, because the dream cycle decides what (if anything)
/// is vault-worthy later; the raw transcript must never pollute the curated wiki.
///
/// Stateless value type: it only knows its directory, so it's trivially `Sendable` and
/// testable against a temp dir. Re-stashing a thread overwrites (`<threadID>.json`), so a
/// growing conversation updates in place and a re-run never double-files (the dedupe the
/// dream-cycle idempotency risk in PLAN-brain.md §7 calls for).
struct ConversationStash {
    let directory: URL

    init(directory: URL? = nil) throws {
        self.directory = directory ?? AppSupport.subdirectory("stash")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Hot-path eligibility (ADR 0015): only Ask threads and conversations the user grew
    /// into a real multi-turn discussion are stashed live. A bare quick-action transform
    /// is left for the dream cycle to pull from history + substance-filter — it doesn't
    /// belong in the live stash. (A freshly seeded thread is the [seed, result, follow-up]
    /// triple, so > 3 turns means the user kept talking.)
    static func isEligible(isAsk: Bool, turnCount: Int) -> Bool {
        isAsk || turnCount > 3
    }

    func stash(_ convo: StashedConversation) throws {
        let data = try JSONEncoder().encode(convo)
        try data.write(to: fileURL(convo.threadID), options: .atomic)
    }

    /// All stashed conversations, oldest first — the dream cycle's input batch.
    func loadAll() -> [StashedConversation] {
        let dec = JSONDecoder()
        return jsonFiles()
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? dec.decode(StashedConversation.self, from: $0) }
            .sorted { $0.stampMillis < $1.stampMillis }
    }

    func remove(threadID: Int64) {
        try? FileManager.default.removeItem(at: fileURL(threadID))
    }

    /// Drop everything — called once the dream cycle has consumed the batch.
    func clear() {
        for url in jsonFiles() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: -

    private func fileURL(_ threadID: Int64) -> URL {
        directory.appendingPathComponent("\(threadID).json")
    }

    private func jsonFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
    }
}
