import Foundation

/// Records the last fingerprint synthesized per person page path, so each pass only
/// re-synthesizes when the connection bullets actually change. A sidecar JSON in
/// app-support (NOT the vault) — mirrors how `ProjectSyncStore` lives outside the vault,
/// keeping the brain's git history free of sync-pointer churn.
struct PeopleSynthStore {
    let fileURL: URL

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("people-synth.json")
    }

    func lastFingerprint(forPath path: String) -> String? { load()[path] }

    func record(path: String, fingerprint: String) {
        var map = load(); map[path] = fingerprint
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
}
