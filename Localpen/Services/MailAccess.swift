import Foundation

/// Mail-context configuration (ADR 0019, source #3): the user's opt-in toggle for
/// reading recent inbox mail as ask context, plus discovery of the local Mail store.
///
/// Unlike Files (which reuses Accessibility) this source reads `~/Library/Mail`, a
/// TCC-protected location — so it needs **Full Disk Access**. There's no API to query
/// that grant; instead `storeURL` returns the Envelope Index path and the source treats
/// an unreadable store as "nothing to add" (capture returns nil), so a missing grant
/// degrades gracefully rather than crashing.
enum MailAccess {
    private static let enabledKey = "mailContextEnabled"

    /// The user's Settings toggle. Default false — off until enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hot-path gate consulted before any DB/file work. Just the toggle; the FDA
    /// "authorization" is implicit — an unreadable store yields no context.
    static var isActive: Bool { isEnabled }

    /// The "recent" window the picker shows by default — the last day of inbox mail
    /// (a time window, not an arbitrary count: "recent" means "since yesterday", however
    /// many that is).
    static let recentWindowHours = 24

    /// Max rows the recent view / a search returns (header-only, cheap).
    static let listLimit = 40

    /// Per-message body cap for an attached email. Short personal mail comes through
    /// whole; a long newsletter is truncated. Mirrors `FilesAccess.bodyCharCap` intent.
    static let bodyCharCap = 2000

    /// The Mail container root (`~/Library/Mail`). TCC-protected.
    static let mailRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mail", isDirectory: true)

    /// Path to the newest store's `Envelope Index` SQLite, or nil if no `V*` store
    /// exists / it's unreadable (e.g. no Full Disk Access). Picks the highest `V`
    /// number so we follow Apple's store-format bumps (V10 on macOS 26).
    static func storeURL() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mailRoot, includingPropertiesForKeys: nil) else { return nil }
        let versionDir = entries
            .filter { $0.lastPathComponent.hasPrefix("V") &&
                      Int($0.lastPathComponent.dropFirst()) != nil }
            .max { (Int($0.lastPathComponent.dropFirst()) ?? 0) <
                   (Int($1.lastPathComponent.dropFirst()) ?? 0) }
        guard let versionDir else { return nil }
        let index = versionDir
            .appendingPathComponent("MailData", isDirectory: true)
            .appendingPathComponent("Envelope Index")
        return FileManager.default.isReadableFile(atPath: index.path) ? index : nil
    }
}
