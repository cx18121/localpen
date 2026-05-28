import Foundation
import AppKit
import ApplicationServices

/// Cheap context capture for free-form Ask. Reads frontmost app name (no
/// permission), focused window title (off-main, AX-timeout-bounded), and
/// optionally reuses an already-paid TextIO capture so the hotkey path
/// doesn't double-pay the ~90ms clipboard settle.
///
/// **Off-main AX read is load-bearing.** `AXUIElementCopyAttributeValue` is
/// synchronous C and can block; Task cancellation cannot preempt blocked C.
/// The freeze guard is `AXUIElementSetMessagingTimeout` at the AX layer,
/// combined with running the read on a detached Task so the main actor stays
/// responsive.
///
/// **Single-capture invariant is load-bearing.** Callers that already paid
/// for capture (notably `PanelController.captureAndShow`) pass the result
/// via `reusingCapture`; the probe does not re-invoke TextIO.
final class ContextProbe {

    // MARK: Snapshot

    struct Snapshot: Sendable, Equatable {
        let appName: String?
        let windowTitle: String?
        let selection: String?
    }

    // MARK: Injection seams

    protocol AXWindowTitleReader: Sendable {
        func readWindowTitle(pid: pid_t, timeoutSeconds: Float) -> String?
    }

    protocol SelectionCapturing: Sendable {
        func captureSelectionForProbe() async -> String?
    }

    private let axReader: any AXWindowTitleReader
    private let textIO: any SelectionCapturing
    private let appName: @Sendable () -> String?
    private let pid: @Sendable () -> pid_t

    init(axReader: any AXWindowTitleReader = SystemAXWindowTitleReader(),
         textIO: any SelectionCapturing = TextIOProbeAdapter(),
         appName: @escaping @Sendable () -> String? = {
             NSWorkspace.shared.frontmostApplication?.localizedName
         },
         pid: @escaping @Sendable () -> pid_t = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
         }) {
        self.axReader = axReader
        self.textIO = textIO
        self.appName = appName
        self.pid = pid
    }

    // MARK: Capture

    /// Capture cheap context. If `reusingCapture` is non-nil, its selection
    /// and sourceAppName are reused. If nil, the probe calls TextIO and
    /// NSWorkspace itself.
    func capture(reusingCapture: TextIO.Capture?) async -> Snapshot {
        let resolvedAppName: String?
        let selectionTextRaw: String?

        if let cap = reusingCapture {
            resolvedAppName = cap.sourceAppName
            selectionTextRaw = cap.selection
        } else {
            resolvedAppName = appName()
            selectionTextRaw = await textIO.captureSelectionForProbe()
        }
        let normalizedSelection = (selectionTextRaw ?? "").isEmpty ? nil : selectionTextRaw

        // Off-main AX read with AX-layer timeout. The detached Task keeps
        // the main actor free; the timeoutSeconds value is passed to the
        // AX call's AXUIElementSetMessagingTimeout, which IS
        // preemption-effective.
        let pidValue = pid()
        let reader = axReader
        let windowTitle: String? = await Task.detached(priority: .userInitiated) {
            reader.readWindowTitle(pid: pidValue, timeoutSeconds: 0.15)
        }.value

        return Snapshot(appName: resolvedAppName,
                        windowTitle: windowTitle,
                        selection: normalizedSelection)
    }
}

// MARK: Production AX reader

/// Production implementation: sets AX messaging timeout BEFORE the
/// attribute read so the synchronous C call cannot block longer than
/// `timeoutSeconds`.
struct SystemAXWindowTitleReader: ContextProbe.AXWindowTitleReader {
    func readWindowTitle(pid: pid_t, timeoutSeconds: Float) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)
        var windowRef: CFTypeRef?
        let windowErr = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
        // CFTypeRef → AXUIElement guard mirrors the `as? String` pattern on
        // the title line below. Defensive against a pathological AX tree
        // returning the wrong CF type for this attribute.
        guard windowErr == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let win = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(win, timeoutSeconds)
        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        guard titleErr == .success, let title = titleRef as? String else { return nil }
        return title.isEmpty ? nil : title
    }
}

// MARK: Production TextIO adapter

/// Bridges TextIO (which exposes Capture) to the probe's selection-only
/// need. Used only when `reusingCapture` is nil — i.e. callers that didn't
/// already pay for capture.
struct TextIOProbeAdapter: ContextProbe.SelectionCapturing {
    func captureSelectionForProbe() async -> String? {
        let io = await MainActor.run { TextIO() }
        return await io.captureSelection().selection
    }
}
