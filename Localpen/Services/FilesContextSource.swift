import Foundation
import AppKit
import ApplicationServices
import PDFKit

/// Files context source (ADR 0019, source #1): reads "the file you have open" — the
/// document of the frontmost app's focused window, via the AX `kAXDocumentAttribute`
/// (reuses the Accessibility permission Localpen already holds; no new prompt). The
/// file's text rides along as one `<context>` line, capped. Returns nil when the
/// source is disabled, there's no document (a browser tab, an untitled buffer), or the
/// file isn't readable text/PDF — in which case nothing is added (graceful, no noise).
struct FilesContextSource: ContextSource {
    let kind: ContextKind = .files
    let isEnabled: @Sendable () -> Bool
    private let reader: any DocumentURLReading
    private let pid: @Sendable () -> pid_t
    private let readBody: @Sendable (URL) -> String

    init(isEnabled: @escaping @Sendable () -> Bool = { FilesAccess.isActive },
         reader: any DocumentURLReading = SystemAXDocumentReader(),
         pid: @escaping @Sendable () -> pid_t = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
         },
         readBody: @escaping @Sendable (URL) -> String = FilesContextSource.readFileBody) {
        self.isEnabled = isEnabled
        self.reader = reader
        self.pid = pid
        self.readBody = readBody
    }

    func capture() async -> ContextItem? {
        guard isEnabled() else { return nil }
        let reader = self.reader
        let pidValue = pid()
        // AX read off-main with an AX-layer timeout, exactly like the window-title read.
        // Explicit `operation:` label so the closure isn't parsed as the guard body.
        let url = await Task.detached(priority: .userInitiated, operation: {
            reader.frontmostDocumentURL(pid: pidValue, timeoutSeconds: 0.15)
        }).value
        guard let url else { return nil }
        let body = self.readBody
        let text = await Task.detached(priority: .utility, operation: { body(url) }).value
        return .file(name: url.lastPathComponent, body: text)
    }

    /// Extensions read as plain text. Anything else (rich formats, binaries) contributes
    /// only its filename — never raw bytes interpreted as text.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "rtf", "csv", "json", "yaml", "yml", "toml",
        "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp", "hpp",
        "java", "kt", "rb", "sh", "html", "css", "xml", "log", "tex"
    ]

    /// Read + condense a file's text for the prompt. PDFs via PDFKit; allow-listed
    /// text extensions read as UTF-8; everything else returns "" (filename only).
    /// Reuses `ContextEngine.condense` so file context is capped the same way KB pages are.
    static func readFileBody(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let raw: String
        if ext == "pdf" {
            raw = PDFDocument(url: url)?.string ?? ""
        } else if textExtensions.contains(ext) {
            raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        } else {
            return ""
        }
        return ContextEngine.condense(raw, charCap: FilesAccess.bodyCharCap)
    }
}

// MARK: - AX document-URL reader

/// Reads the file URL of the frontmost app's focused window via `kAXDocumentAttribute`.
/// A `Sendable` seam (sibling to `AXWindowTitleReader`) so `FilesContextSource` is
/// testable without a live AX tree.
protocol DocumentURLReading: Sendable {
    func frontmostDocumentURL(pid: pid_t, timeoutSeconds: Float) -> URL?
}

/// Production impl: sets the AX messaging timeout before the synchronous reads so a
/// pathological app can't block the probe, mirroring `SystemAXWindowTitleReader`.
struct SystemAXDocumentReader: DocumentURLReading {
    func frontmostDocumentURL(pid: pid_t, timeoutSeconds: Float) -> URL? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let win = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(win, timeoutSeconds)
        var docRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef) == .success,
              let path = docRef as? String else { return nil }
        // kAXDocumentAttribute is a file URL string ("file:///…"); fall back to a raw path.
        let url = URL(string: path) ?? URL(fileURLWithPath: path)
        return url.isFileURL ? url : nil
    }
}
