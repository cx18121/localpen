import Foundation

/// The Localpen Application Support directory and its subfolders. One definition of the
/// `~/Library/Application Support/Localpen` path — with the `NSHomeDirectory()` fallback for
/// the rare case the system query fails — so it can't drift across `ModelRegistry`,
/// `Persistence`, `BrainIndex`, and the curation stores, each of which used to re-spell it.
enum AppSupport {
    /// `…/Application Support/Localpen`, created if needed.
    static func root() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A named subfolder under the Localpen support dir (e.g. "models", "stash"), created if needed.
    static func subdirectory(_ name: String) -> URL {
        let dir = root().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
