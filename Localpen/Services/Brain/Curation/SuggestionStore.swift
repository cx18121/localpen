import Foundation

/// A high-judgment curation proposal the dream cycle could not safely auto-apply (ADR
/// 0015) — surfaced for one-click apply/dismiss (or handing to a Claude Code session).
/// `id` is content-derived so the same proposal across nightly runs de-dupes instead of
/// piling up.
struct Suggestion: Codable, Equatable, Sendable {
    let id: String
    let kind: String          // the CurationWrite kind, for display/grouping
    let summary: String       // one-line human description
    let createdMillis: Int64

    /// The proposed write, re-encoded so a future "apply" can replay it.
    let payload: SuggestionPayload
}

/// Flat, Codable mirror of a high-judgment `CurationWrite` (the enum isn't Codable; this
/// keeps persistence explicit and forward-compatible).
struct SuggestionPayload: Codable, Equatable, Sendable {
    let kind: String
    var title, body, page, detail, name, into, from: String?
}

extension Suggestion {
    /// Build a suggestion from a high-judgment write. Returns nil for additive writes —
    /// those are auto-applied, never queued (the classifier is the single source of truth).
    init?(highJudgment write: CurationWrite, nowMillis: Int64) {
        guard WriteClassifier.disposition(for: write) == .queueSuggestion else { return nil }
        let d = Suggestion.describe(write)
        self.init(id: Suggestion.stableID(d.kind, d.summary),
                  kind: d.kind, summary: d.summary, createdMillis: nowMillis, payload: d.payload)
    }

    private static func describe(_ w: CurationWrite) -> (kind: String, summary: String, payload: SuggestionPayload) {
        switch w {
        case .rewriteCuratedPage(let title, let body):
            return ("rewriteCuratedPage", "Rewrite “\(title)”", .init(kind: "rewriteCuratedPage", title: title, body: body))
        case .promoteTopic(let title):
            return ("promoteTopic", "Promote topic “\(title)”", .init(kind: "promoteTopic", title: title))
        case .resolveContradiction(let page, let detail):
            return ("resolveContradiction", "Resolve a contradiction in “\(page)”", .init(kind: "resolveContradiction", page: page, detail: detail))
        case .createPerson(let name):
            return ("createPerson", "Add a new person: \(name)", .init(kind: "createPerson", name: name))
        case .mergeIdentities(let into, let from):
            return ("mergeIdentities", "Merge “\(from)” into “\(into)”", .init(kind: "mergeIdentities", into: into, from: from))
        case .captureToInbox, .appendTimeline, .createSource, .nominateLink, .updateNow:
            // Additive — never reached (the init guards on disposition), but keep total.
            return ("additive", "", .init(kind: "additive"))
        }
    }

    /// Deterministic content id (FNV-1a hex) so the same proposal across nightly runs maps
    /// to the same file and overwrites rather than duplicating. Swift's `hashValue` is
    /// per-process randomized, so it can't be used for a stable on-disk key.
    private static func stableID(_ kind: String, _ summary: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(kind)|\(summary)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Disk-backed queue of high-judgment suggestions, under the Localpen-private dir (not the
/// vault — these aren't written until the user applies them). One file per suggestion id,
/// so enqueuing the same proposal twice overwrites (idempotent across nightly re-runs).
struct SuggestionStore {
    let directory: URL

    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            self.directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Localpen/suggestions", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func add(_ suggestion: Suggestion) throws {
        let data = try JSONEncoder().encode(suggestion)
        try data.write(to: fileURL(suggestion.id), options: .atomic)
    }

    func all() -> [Suggestion] {
        let dec = JSONDecoder()
        return jsonFiles()
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? dec.decode(Suggestion.self, from: $0) }
            .sorted { $0.createdMillis < $1.createdMillis }
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    // MARK: -

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func jsonFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
    }
}
