import Foundation

/// The voice-card / memory inspect-and-edit state (ADR 0006 memory), extracted from
/// PanelController so ProfileView binds one focused model. It owns the editable draft + the
/// eligible-interaction count and the memory/persistence reads behind them; the panel
/// *transition* to the profile surface stays on PanelController (it sets `state`).
@MainActor
@Observable
final class ProfileModel {
    var draft: StyleProfile = StyleProfile()
    var eligibleCount: Int = 0

    @ObservationIgnored private let memory: MemoryService?
    @ObservationIgnored private let persistence: Persistence?

    init(memory: MemoryService?, persistence: Persistence?) {
        self.memory = memory
        self.persistence = persistence
    }

    /// Load the current profile + eligible count for display. Returns false when memory is off
    /// (the caller then declines to transition to the profile surface).
    func prepareForShow() -> Bool {
        guard let memory else { return false }
        draft = memory.currentProfile()
        Task {
            if let persistence {
                eligibleCount = await persistence.eligibleInteractionCount(since: draft.forgottenBefore)
            }
        }
        return true
    }

    func saveEdits() {
        guard let memory else { return }
        var d = draft
        d.userEdited = true
        Task { await memory.saveProfile(d) }
    }

    func regenerateNow() {
        guard let memory else { return }
        // Clear userEdited so the regen isn't suppressed; reuse the eligible count.
        Task {
            var current = memory.currentProfile()
            current.userEdited = false
            await memory.saveProfile(current)
            let count = await (persistence?.eligibleInteractionCount(since: current.forgottenBefore) ?? 0)
            memory.scheduleGeneration(eligibleAt: count)
        }
    }

    func forgetEverything() {
        guard let memory else { return }
        Task {
            await memory.forget()
            draft = memory.currentProfile()
        }
    }
}
