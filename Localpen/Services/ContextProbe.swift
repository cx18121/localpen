import Foundation

/// Cheap context capture for free-form Ask. Task 5 fills in `capture(...)`
/// and the AX/TextIO injection seams. This minimal shell exists so
/// `AskContext.from(_ snapshot:)` can be tested in Task 4 without the
/// full implementation.
final class ContextProbe {
    struct Snapshot: Sendable, Equatable {
        let appName: String?
        let windowTitle: String?
        let selection: String?
    }
    // Task 5 will add: AXWindowTitleReader, SelectionCapturing protocols,
    // SystemAXWindowTitleReader, TextIOProbeAdapter, and capture(reusingCapture:).
}
