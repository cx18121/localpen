import Foundation
import os

/// The nightly dream cycle (ADR 0015): batch-synthesize the day's stashed conversations
/// (+ inbox texts) with the curation 14B, then route each proposed write — additive ones
/// auto-applied to the vault, high-judgment ones queued as suggestions. The stash is
/// cleared only on a successful synthesis, so a model-unavailable night just defers.
///
/// Orchestration over injected collaborators (mirrors ModelSwitcher/CurationModel) so the
/// whole gather→synthesize→route→clear flow is testable without a model or a real vault.
@MainActor
final class DreamCycle {
    /// Runs one synthesis pass for the given (system, user) prompt — production wraps
    /// `CurationModel.synthesize` (transient 14B borrow); tests return a canned outcome.
    let synthesize: (_ system: String, _ user: String) async -> CurationModel.RunOutcome
    let stash: ConversationStash
    /// Extra raw inputs beyond the stash (e.g. raw/inbox/ texts). Empty is fine.
    let loadInboxTexts: () -> [String]
    let writer: VaultWriter
    let suggestions: SuggestionStore
    let nowMillis: () -> Int64

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "DreamCycle")

    init(synthesize: @escaping (String, String) async -> CurationModel.RunOutcome,
         stash: ConversationStash,
         writer: VaultWriter,
         suggestions: SuggestionStore,
         loadInboxTexts: @escaping () -> [String] = { [] },
         nowMillis: @escaping () -> Int64) {
        self.synthesize = synthesize
        self.stash = stash
        self.writer = writer
        self.suggestions = suggestions
        self.loadInboxTexts = loadInboxTexts
        self.nowMillis = nowMillis
    }

    struct Report: Equatable {
        var applied = 0       // additive writes committed to the vault
        var queued = 0        // high-judgment proposals enqueued
        var failed = 0        // writes/enqueues that errored
        var consideredItems = 0
        var ranSynthesis = false
        var note = ""         // why nothing ran, when applicable
    }

    func run() async -> Report {
        var report = Report()

        // 1. Gather + substance-filter the batch.
        let convoTexts = stash.loadAll()
            .filter { SubstanceFilter.shouldConsider($0) }
            .map { transcript($0) }
        let items = convoTexts + loadInboxTexts()
        report.consideredItems = items.count
        guard !items.isEmpty else {
            report.note = "nothing to curate"
            return report
        }

        // 2. Synthesize with the curation model.
        let outcome = await synthesize(CurationSynthesis.systemPrompt(),
                                       CurationSynthesis.userPrompt(items: items))
        switch outcome {
        case .skipped(let reason):
            // Model unavailable — DON'T clear the stash; try again next run.
            report.note = "synthesis skipped: \(reason)"
            return report
        case .failed(let message, _):
            report.note = "synthesis failed: \(message)"
            return report
        case .completed(let text):
            report.ranSynthesis = true
            route(CurationSynthesis.parse(text), into: &report)
        }

        // 3. Clear the processed stash (idempotent — a re-run won't double-file).
        stash.clear()
        log.info("dream cycle: applied \(report.applied) queued \(report.queued) failed \(report.failed)")
        return report
    }

    // MARK: -

    /// Route each parsed write by the classifier: additive → vault, high-judgment → queue.
    private func route(_ writes: [CurationWrite], into report: inout Report) {
        for write in writes {
            switch WriteClassifier.disposition(for: write) {
            case .autoApply:
                do { _ = try writer.apply(write, nowMillis: nowMillis()); report.applied += 1 }
                catch {
                    report.failed += 1
                    log.error("additive write failed: \(error.localizedDescription, privacy: .public)")
                }
            case .queueSuggestion:
                guard let suggestion = Suggestion(highJudgment: write, nowMillis: nowMillis()) else {
                    report.failed += 1; continue
                }
                do { try suggestions.add(suggestion); report.queued += 1 }
                catch {
                    report.failed += 1
                    log.error("enqueue suggestion failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Render a stashed conversation as plain text for the synthesis prompt.
    private func transcript(_ c: StashedConversation) -> String {
        c.turns.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
    }
}
