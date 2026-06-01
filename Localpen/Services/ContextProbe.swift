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
        /// Formatted upcoming-calendar context (ADR 0012), or nil when calendar
        /// context is disabled/unauthorized/empty. Read once at capture and
        /// frozen for the session — the probe's single-capture invariant means a
        /// long-open thread shows this point-in-time snapshot, not live schedule.
        let calendar: String?

        // Explicit init so `calendar` defaults to nil for the non-calendar call
        // sites (a `let`-optional doesn't get an implicit memberwise default).
        init(appName: String?, windowTitle: String?, selection: String?, calendar: String? = nil) {
            self.appName = appName
            self.windowTitle = windowTitle
            self.selection = selection
            self.calendar = calendar
        }
    }

    // MARK: Injection seams

    protocol AXWindowTitleReader: Sendable {
        func readWindowTitle(pid: pid_t, timeoutSeconds: Float) -> String?
    }

    protocol SelectionCapturing: Sendable {
        func captureSelectionForProbe() async -> String?
    }

    /// Read-only calendar source (ADR 0012/0013). Returns the formatted context
    /// line or nil. Sendable so it can run in the off-main detached step; the
    /// production impl (`ICSCalendarReader`) is a stateless struct over a cache.
    protocol CalendarReading: Sendable {
        func upcomingContext() -> String?
    }

    private let axReader: any AXWindowTitleReader
    private let textIO: any SelectionCapturing
    private let calendarReader: any CalendarReading
    private let appName: @Sendable () -> String?
    private let pid: @Sendable () -> pid_t
    /// Synchronous gate for the calendar read — `CalendarAccess.isActive` in
    /// production (user toggle ON and authorization granted). When false the
    /// probe skips the calendar fetch entirely, so the ask path is never blocked
    /// and the prompt is byte-identical to calendar-never-existed.
    private let isCalendarAuthorized: @Sendable () -> Bool

    init(axReader: any AXWindowTitleReader = SystemAXWindowTitleReader(),
         textIO: any SelectionCapturing = TextIOProbeAdapter(),
         calendarReader: any CalendarReading = ICSCalendarReader(),
         appName: @escaping @Sendable () -> String? = {
             NSWorkspace.shared.frontmostApplication?.localizedName
         },
         pid: @escaping @Sendable () -> pid_t = {
             NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
         },
         isCalendarAuthorized: @escaping @Sendable () -> Bool = { CalendarAccess.isActive }) {
        self.axReader = axReader
        self.textIO = textIO
        self.calendarReader = calendarReader
        self.appName = appName
        self.pid = pid
        self.isCalendarAuthorized = isCalendarAuthorized
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

        let calendar = await readCalendarOffMain()

        return Snapshot(appName: resolvedAppName,
                        windowTitle: windowTitle,
                        selection: normalizedSelection,
                        calendar: calendar)
    }

    /// Reads the calendar context off-main, gated by `isCalendarAuthorized`.
    /// Exposed so the no-capture hover entry (`PanelController.showFromHover`),
    /// which builds its AskContext without running the full probe, can still
    /// attach calendar context. Returns nil when disabled/unauthorized/empty.
    func readCalendarOffMain() async -> String? {
        guard isCalendarAuthorized() else { return nil }
        let reader = calendarReader
        return await Task.detached(priority: .userInitiated) {
            reader.upcomingContext()
        }.value
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
