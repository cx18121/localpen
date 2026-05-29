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

        /// A capture with no selection, no source app, and no saved clipboard —
        /// used when synthesizing a session that didn't originate from a hotkey
        /// capture (e.g. resuming a stored thread). `pasteBack` against this hits
        /// the deny-list/skip path and falls back to leaving the result on the
        /// clipboard, which is correct: there is no original field to paste into.
        static let empty = Capture(
            selection: nil, sourceBundleID: nil, sourceAppName: nil,
            savedFrontmostApp: nil, savedItems: []
        )
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

        // The hotkey (e.g. ⌃⌥Space) is almost certainly still physically held when
        // we get here. Left alone, the window server ORs those live modifiers into
        // our injected ⌘C, turning it into ⌃⌥⌘C — which no app treats as Copy. Rather
        // than wait for the user to release the keys (a visible delay), `postCmdChord`
        // suppresses local hardware modifiers during the synthetic chord, so the copy
        // lands clean immediately. A short settle lets the target write the pasteboard.
        postCmdChord(keyCode: CGKeyCode(kVK_ANSI_C))
        try? await Task.sleep(for: .milliseconds(90))

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

        // Bring the source app back to the front and wait until it is actually
        // frontmost before synthesizing ⌘V — otherwise the keystroke lands in
        // Localpen (or nowhere) and nothing pastes.
        capture.savedFrontmostApp?.activate()
        await waitUntilFrontmost(capture.savedFrontmostApp, timeout: .milliseconds(700))

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        log.notice("pasteBack: target=\(capture.sourceBundleID ?? "nil", privacy: .public) frontmostAtPaste=\(front ?? "nil", privacy: .public)")

        postCmdChord(keyCode: CGKeyCode(kVK_ANSI_V))
        // Give the target app time to read the pasteboard before we restore the
        // user's previous clipboard; restoring too early pastes the old content.
        try? await Task.sleep(for: .milliseconds(150))

        restorePasteboard(capture.savedItems)
        return .pasted
    }

    /// Polls until `app` becomes frontmost or the timeout elapses, so a
    /// just-activated app has actually taken focus before we synthesize keys.
    private func waitUntilFrontmost(_ app: NSRunningApplication?, timeout: Duration) async {
        guard let app else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Restore the pasteboard captured at hotkey time. Call on any dismissal
    /// path that didn't go through `pasteBack` (e.g., Escape, back-to-menu
    /// followed by Escape). Without this, every cancel leaks the user's
    /// pasteboard with the captured selection.
    func restoreClipboard(_ capture: Capture) {
        restorePasteboard(capture.savedItems)
    }

    private func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        // Nothing was captured (hover/click open and resumed-thread teardown use
        // an empty capture): the user's real OS clipboard was never touched, so
        // leave it alone. Without this guard, clearContents() below wipes whatever
        // the user had copied elsewhere and writes nothing back — silent data loss.
        guard !items.isEmpty else { return }
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
        // Suppress physically-held hardware modifiers (the ⌃⌥ from the summoning
        // hotkey) for the brief interval around our synthetic events, so they aren't
        // OR'd into the chord. This lets ⌘C/⌘V land clean while the hotkey is still
        // held — no need to wait for the user to release it. We omit
        // `.permitLocalKeyboardEvents` from the permitted set so local modifier state
        // is filtered during the suppression interval.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

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
