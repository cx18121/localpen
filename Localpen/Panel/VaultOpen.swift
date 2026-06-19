import AppKit

/// Opens a vault markdown file in Obsidian explicitly, instead of via the system's default
/// `.md` handler — which on some machines is a terminal (e.g. Warp), so a note "open" would
/// drop the file into a shell. cxkb is an Obsidian vault, so notes belong in Obsidian. Falls
/// back to the OS default handler only when Obsidian isn't installed.
enum VaultOpen {
    private static let obsidianBundleID = "md.obsidian"

    static func open(_ fileURL: URL) {
        if let obsidian = NSWorkspace.shared.urlForApplication(withBundleIdentifier: obsidianBundleID) {
            NSWorkspace.shared.open([fileURL], withApplicationAt: obsidian,
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(fileURL)   // no Obsidian — honor the system default
        }
    }
}
