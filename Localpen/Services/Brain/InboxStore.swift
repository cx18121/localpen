import Foundation

/// Reads and writes the vault's `raw/inbox/` — the sanctioned drop zone for quick captures
/// and bridged notes (ADR 0015) the dream cycle later files. Pure file access over a vault
/// root, so the hub controller doesn't hand-roll FileManager enumeration + heading parsing,
/// and the logic is testable without a PanelController.
struct InboxStore {
    let vaultRoot: URL

    private var directory: URL {
        vaultRoot.appendingPathComponent("raw/inbox", isDirectory: true)
    }

    /// Titles of the most recently-modified inbox items (the briefing's "fresh" section):
    /// each item's first `# heading`, else its filename. Most-recent first.
    func recentTitles(limit: Int = 6) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "md" } ?? []
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }.prefix(limit).map(Self.title)
    }

    /// Write a quick capture as a timestamped inbox file (ADR 0015 additive write). Throws on
    /// a filesystem failure so the caller can surface it. The write is genuinely additive: two
    /// captures in the same second get distinct `…-2.md`, `…-3.md` names rather than the later
    /// silently overwriting the earlier (the stamp has only second resolution).
    @discardableResult
    func capture(_ text: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(base: Self.stamp(now))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `<base>.md`, or `<base>-2.md`, `<base>-3.md`, … if earlier captures already claimed it.
    /// Captures are @MainActor-driven (no concurrent writers), so a plain existence check is safe.
    private func uniqueURL(base: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return candidate
    }

    /// Most-recent inbox items as (title, file URL) — so the hub can show them AND open each
    /// in Obsidian for review/triage. Same ordering as `recentTitles`.
    func recentItems(limit: Int = 6) -> [(title: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "md" } ?? []
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }.prefix(limit).map { (Self.title($0), $0) }
    }

    /// The full text of every inbox item — the dream cycle's raw input alongside the stash.
    func bodies() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The current top-level inbox `.md` files (the `.archive/` subdir is excluded — it's a
    /// directory, not a `.md`). Snapshotted before a dream cycle so exactly the consumed files
    /// are archived afterward, never a capture that arrived mid-run.
    func itemURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
    }

    /// Move curated inbox files into `raw/inbox/.archive/` so the dream cycle doesn't
    /// re-synthesize them every run. Best-effort (a failed move stays in place → retried next
    /// cycle). `.archive/` is under `raw/`, which the brain index excludes, so archived
    /// captures stay out of retrieval. `bodies()`/`itemURLs()` skip the subdir.
    func archive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let archiveDir = directory.appendingPathComponent(".archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        for url in urls {
            var dest = archiveDir.appendingPathComponent(url.lastPathComponent)
            let base = url.deletingPathExtension().lastPathComponent
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = archiveDir.appendingPathComponent("\(base)-\(n).md"); n += 1
            }
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    /// The first `# heading` of an inbox file, else its filename — a readable label.
    static func title(_ url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let heading = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) {
            return String(heading.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }
}
