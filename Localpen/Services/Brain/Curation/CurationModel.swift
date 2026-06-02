import Foundation
import os

/// Runs the heavy curation model (ADR 0015) transiently for one synthesis pass, then
/// restores the transform model. llama-server hosts one model at a time, and the 14B is
/// "not kept warm" — so the dream cycle borrows the server: stop the 7B, bring up the
/// 14B, synthesize, bring the 7B back.
///
/// Unlike `ModelSwitcher`, this **never commits the active-model pointer** — the switch is
/// ephemeral, so a relaunch still resolves the user's transform model. And it **always
/// restores the transform model afterward** (success or failure), because leaving the
/// latency-critical transform path pointed at a dead/oversized server is the worst
/// outcome; if the restore itself fails, that's surfaced (`transformModelRestored:false`),
/// never swallowed.
///
/// Pure orchestration over injected collaborators (mirrors `ModelSwitcher`) so the
/// borrow-and-restore contract is unit-testable without a real llama-server or GGUF.
@MainActor
struct CurationModel {
    /// Start the server for a model at `path`/`contextSize`; throws on launch/health failure.
    let start: (_ path: String, _ contextSize: Int) async throws -> Void
    /// Stop the running server.
    let stop: () -> Void
    /// Run ONE full completion against the running server and return the concatenated
    /// text (the dream cycle wants the whole synthesis, not a UI token stream). Injected
    /// so tests don't need a live server; production wraps `StreamingClient.complete`.
    let complete: (_ systemPrompt: String, _ userText: String,
                   _ sampling: ModelDescriptor.Sampling) async throws -> String

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "CurationModel")

    /// The curation model to bring up for the pass.
    struct Stage: Equatable {
        let path: String
        let contextSize: Int
        let sampling: ModelDescriptor.Sampling
    }
    /// The transform model to restore afterward (no sampling needed — we only relaunch it).
    struct RestoreStage: Equatable {
        let path: String
        let contextSize: Int
    }

    enum RunOutcome: Equatable {
        /// Synthesis text from the 14B, transform model restored.
        case completed(text: String)
        /// The curation model isn't downloaded — nothing ran, transform model untouched.
        case skipped(reason: String)
        /// The pass failed (start or synthesis). `transformModelRestored` is false only
        /// if we also could not bring the transform model back — a state the caller must
        /// surface loudly (transforms are now broken until a relaunch/manual restart).
        case failed(message: String, transformModelRestored: Bool)
    }

    /// Borrow the server: bring up `curation`, run one synthesis completion, restore
    /// `restore`. Pointer is never committed.
    func synthesize(systemPrompt: String, userText: String,
                    curation: Stage, restore: RestoreStage,
                    isDownloaded: Bool) async -> RunOutcome {
        guard isDownloaded else {
            return .skipped(reason: "curation model not downloaded")
        }

        stop()
        do {
            try await start(curation.path, curation.contextSize)
        } catch {
            // The 14B never came up: restore the transform model so the latency path
            // keeps working. Nothing was generated.
            let restored = await restoreTransformModel(restore)
            log.error("curation model failed to start: \(error.localizedDescription, privacy: .public)")
            return .failed(message: "curation model failed to start: \(error.localizedDescription)",
                           transformModelRestored: restored)
        }

        // The 14B is up. Whatever happens, restore the transform model before returning.
        let synthesis: Result<String, Error>
        do {
            synthesis = .success(try await complete(systemPrompt, userText, curation.sampling))
        } catch {
            synthesis = .failure(error)
        }
        let restored = await restoreTransformModel(restore)

        switch synthesis {
        case .success(let text):
            return restored
                ? .completed(text: text)
                : .failed(message: "synthesis succeeded but the transform model did not restart",
                          transformModelRestored: false)
        case .failure(let error):
            log.error("curation synthesis failed: \(error.localizedDescription, privacy: .public)")
            return .failed(message: "curation synthesis failed: \(error.localizedDescription)",
                           transformModelRestored: restored)
        }
    }

    /// Bring the transform model back up. Returns false if it would not start — the
    /// caller must surface that (transforms are broken until the server is restarted).
    private func restoreTransformModel(_ restore: RestoreStage) async -> Bool {
        stop()
        do {
            try await start(restore.path, restore.contextSize)
            return true
        } catch {
            log.error("FAILED to restore transform model: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
