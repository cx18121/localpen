import Foundation

/// Records the last git SHA summarized per repo, so each nightly pass only reads new commits.
/// A sidecar JSON in app-support (NOT the vault) — mirrors how ConversationStash/SuggestionStore
/// live outside the vault, keeping the brain's git history free of sync-pointer churn.
struct ProjectSyncStore {
    let fileURL: URL

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("project-sync.json")
    }

    func lastSHA(forRepo path: String) -> String? { load()[path] }

    func record(repo path: String, sha: String) {
        var map = load(); map[path] = sha
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
}
