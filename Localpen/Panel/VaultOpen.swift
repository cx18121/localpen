import AppKit

/// Opens a vault markdown file in Obsidian, instead of via the system's default `.md` handler
/// — which on some machines is a terminal (e.g. Warp), so a note "open" would drop the file
/// into a shell. cxkb is an Obsidian vault, so notes belong in Obsidian.
///
/// Uses Obsidian's `obsidian://open?path=…` URI: handing the file to Obsidian.app directly only
/// foregrounds it on a blank tab — the URI is what actually opens the specific note. Falls back
/// to the OS default handler when the `obsidian://` scheme has no handler (Obsidian not installed).
enum VaultOpen {
    static func open(_ fileURL: URL) {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        if let url = comps.url, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(fileURL)   // no obsidian:// handler — honor the system default
    }
}
