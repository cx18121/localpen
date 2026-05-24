import Foundation

// One capture→generate→accept attempt for a single panel summon. Owning the
// per-summon data and async tasks here lets PanelController replace its
// scattered `sessionID == mySession` token checks with one identity
// comparison (`current === session`), and gives the pending-but-unaccepted
// result a single home so it can't drift out of sync. See THERMO-REVIEW #1/#2.
@MainActor
final class PanelSession {
    let id: UInt64
    let capture: TextIO.Capture
    let hotkeyTime: ContinuousClock.Instant

    var streamingTask: Task<Void, Never>?
    var watchdogTask: Task<Void, Never>?

    /// A completed result awaiting the user's decision. On accept it's persisted
    /// as accepted; on any teardown it's persisted as rejected (see
    /// `PanelController.flushPendingAsRejected`).
    var pendingInteraction: Interaction?

    init(id: UInt64, capture: TextIO.Capture, hotkeyTime: ContinuousClock.Instant) {
        self.id = id
        self.capture = capture
        self.hotkeyTime = hotkeyTime
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }
}
