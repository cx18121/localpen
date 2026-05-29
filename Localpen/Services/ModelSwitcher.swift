import Foundation
import os

/// Staged model switch with rollback. The naïve switch persisted the new active
/// model BEFORE proving the server could load it, then stopped the working
/// server — so a corrupt GGUF / timeout / port conflict left the persisted
/// pointer aimed at a model that won't start AND no running server (Codex [high]).
///
/// This stages the switch instead: stop the old server, start the NEW model, and
/// only commit the active-model pointer once the new server is actually ready. On
/// failure it restarts the PREVIOUS model so the user is never left with a dead
/// server, never commits the broken pointer (so a relaunch resolves the still-good
/// previous model), and reports the failure for a visible surface — not a silent log.
///
/// Pure orchestration over injected collaborators so the rollback contract is
/// unit-testable without a real llama-server.
@MainActor
struct ModelSwitcher {
    /// Start the server for a model at `path` with `contextSize`; throws on any
    /// launch / health-check failure. Invoked on the main actor (the type is
    /// `@MainActor`), so it can touch main-actor-isolated collaborators directly.
    let start: (_ path: String, _ contextSize: Int) async throws -> Void
    /// Stop the running server.
    let stop: () -> Void
    /// Persist + flip the active-model pointer. Only called on a proven-good start.
    let commit: (_ id: String) -> Void

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ModelSwitcher")

    enum SwitchOutcome: Equatable {
        case switched(id: String)
        /// The new model failed to start; the previous model has been restarted
        /// (or, if that also failed, `previousRestored == false`). The pointer was
        /// never committed, so a relaunch still resolves the previous model.
        case failed(newID: String, previousID: String, message: String, previousRestored: Bool)
    }

    struct ModelStage {
        let id: String
        let path: String
        let contextSize: Int
    }

    /// Switch from `previous` to `candidate`, committing only on success and
    /// rolling back to `previous` on failure.
    func switchTo(candidate: ModelStage, previous: ModelStage) async -> SwitchOutcome {
        stop()
        do {
            try await start(candidate.path, candidate.contextSize)
            commit(candidate.id)
            log.info("model switch committed: \(candidate.id, privacy: .public)")
            return .switched(id: candidate.id)
        } catch {
            let message = error.localizedDescription
            log.error("model switch to \(candidate.id, privacy: .public) failed: \(message, privacy: .public); rolling back to \(previous.id, privacy: .public)")
            // Roll back: bring the previous, known-good model back up so the user
            // isn't stranded with a dead server. The pointer was never committed.
            var previousRestored = true
            do {
                try await start(previous.path, previous.contextSize)
            } catch {
                previousRestored = false
                log.error("rollback restart of previous model \(previous.id, privacy: .public) also failed: \(error.localizedDescription, privacy: .public)")
            }
            return .failed(newID: candidate.id, previousID: previous.id,
                           message: message, previousRestored: previousRestored)
        }
    }
}
