import AppKit
import Carbon.HIToolbox
import os

@MainActor
final class TextIO {
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "TextIO")

    struct Capture {
        let selection: String?
        let sourceBundleID: String?
        let sourceAppName: String?
        let savedFrontmostApp: NSRunningApplication?
        let savedItems: [[NSPasteboard.PasteboardType: Data]]
    }

    func captureSelection() async -> Capture {
        let pasteboard = NSPasteboard.general
        let frontmost = NSWorkspace.shared.frontmostApplication

        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }
        let beforeCount = pasteboard.changeCount
        log.info("capture: frontmost=\(frontmost?.bundleIdentifier ?? "nil", privacy: .public) pbCountBefore=\(beforeCount)")

        postCmdChord(keyCode: CGKeyCode(kVK_ANSI_C))
        try? await Task.sleep(for: .milliseconds(120))

        let afterCount = pasteboard.changeCount
        let changed = afterCount != beforeCount
        let captured = changed ? pasteboard.string(forType: .string) : nil
        log.info("capture: pbCountAfter=\(afterCount) changed=\(changed) capturedLen=\(captured?.count ?? -1)")

        return Capture(
            selection: captured,
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            savedFrontmostApp: frontmost,
            savedItems: savedItems
        )
    }

    enum PasteBackResult {
        case pasted
        case skipped  // bundle in deny-list; result remains on pasteboard for manual ⌘V
    }

    func pasteBack(result: String, capture: Capture) async -> PasteBackResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)

        if PasteBackDenyList.shouldSkip(capture.sourceBundleID) {
            log.info("pasteBack skipped (deny-list) for \(capture.sourceBundleID ?? "nil", privacy: .public)")
            // Do NOT restore the original pasteboard — user needs the result on the clipboard.
            return .skipped
        }

        capture.savedFrontmostApp?.activate(options: [])
        try? await Task.sleep(for: .milliseconds(80))

        postCmdChord(keyCode: CGKeyCode(kVK_ANSI_V))
        try? await Task.sleep(for: .milliseconds(120))

        restorePasteboard(capture.savedItems)
        return .pasted
    }

    /// Restore the pasteboard captured at hotkey time. Call on any dismissal
    /// path that didn't go through `pasteBack` (e.g., Escape, back-to-menu
    /// followed by Escape). Without this, every cancel leaks the user's
    /// pasteboard with the captured selection.
    func restoreClipboard(_ capture: Capture) {
        restorePasteboard(capture.savedItems)
    }

    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { dataMap in
            let item = NSPasteboardItem()
            for (type, data) in dataMap {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }

    private func postCmdChord(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let kDown   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        kDown?.flags = .maskCommand
        let kUp     = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        kUp?.flags = .maskCommand
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        kDown?.post(tap: .cghidEventTap)
        kUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
