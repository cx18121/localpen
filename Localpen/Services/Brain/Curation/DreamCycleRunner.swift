import Foundation

/// Runs one curation dream-cycle pass against the live transform model (ADR 0017): builds
/// the synthesis closure over the already-loaded llama-server, drives `DreamCycle`, and
/// returns its report. Extracted from `AppDelegate` so the synthesis policy (which model,
/// what sampling, the long timeout) lives next to the curation layer it belongs to rather
/// than in the app-lifecycle object.
@MainActor
struct DreamCycleRunner {
    let server: LlamaServerController
    let stash: ConversationStash
    let suggestions: SuggestionStore
    /// Archive the consumed inbox on a successful cycle (set by AppDelegate from a pre-run
    /// snapshot). Default no-op keeps tests + other callers unchanged.
    var archiveInbox: () -> Void = {}
    let nowMillis: () -> Int64

    /// Faithful, less-inventive synthesis: lower temperature than the interactive transform.
    private static let sampling = ModelDescriptor.Sampling(temperature: 0.3, topP: 0.9, repeatPenalty: 1.05)

    func run() async -> DreamCycle.Report {
        let port = server.port
        let cycle = DreamCycle(
            synthesize: { system, user in
                // Collect the full synthesis (no UI streaming). 10-minute timeout: prompt-eval
                // on a batch far exceeds the 60s interactive default, which timed runs out.
                do {
                    let client = StreamingClient(port: port)
                    var acc = ""
                    for try await tok in client.complete(systemPrompt: system, userText: user,
                                                          sampling: Self.sampling, timeout: 600) {
                        acc += tok
                    }
                    return .completed(acc)
                } catch {
                    return .failed("curation synthesis failed: \(error.localizedDescription)")
                }
            },
            stash: stash,
            writer: VaultWriter(vaultRoot: BrainAccess.vaultRoot),
            suggestions: suggestions,
            loadInboxTexts: { InboxStore(vaultRoot: BrainAccess.vaultRoot).bodies() },
            archiveInbox: archiveInbox,
            nowMillis: nowMillis
        )
        return await cycle.run()
    }
}
