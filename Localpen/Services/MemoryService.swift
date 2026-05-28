import Foundation
import GRDB
import os

@MainActor
class MemoryService {   // not `final`: MemoryRegenerationTests overrides scheduleGeneration to spy without firing llama-server
    let persistence: Persistence
    let streaming: StreamingClient
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Memory")

    /// Cached profile; refreshed after generation or external save. UI inspects it
    /// directly through `currentProfile()`.
    private var cached: StyleProfile = StyleProfile()

    /// Single-flight gate for background generation. Filled by Task 5.
    private var generationTask: Task<Void, Never>?

    /// Post-commit subscription token. Released in deinit.
    private var observer: NSObjectProtocol?

    /// Compose injection thresholds (spec). Held as constants here so tests can pin them.
    static let coldStartGate = 15
    static let regenGrowthFactor = 1.5
    static let exemplarLimit = 5
    static let generationSampleCap = 40

    init(persistence: Persistence, streaming: StreamingClient) {
        self.persistence = persistence
        self.streaming = streaming
        Task { await self.refreshCache() }
        self.observer = NotificationCenter.default.addObserver(
            forName: .interactionPersisted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.interactionDidPersist() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Test-only: detach the auto-subscription so test cases can drive
    /// `interactionDidPersist()` manually without observer-fired races.
    func _detachPostCommitObserverForTests() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refreshCache() async {
        cached = await persistence.loadStyleProfile()
    }

    func currentProfile() -> StyleProfile { cached }

    /// External mutation (UI edit / Regenerate / Forget) re-syncs the cache.
    func saveProfile(_ p: StyleProfile) async {
        await persistence.saveStyleProfile(p)
        cached = p
    }

    func forget(at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async {
        // `at` is unix-epoch MILLISECONDS to match interactions.timestamp post-v4.
        await persistence.forgetMemory(at: at)
        cached = StyleProfile(forgottenBefore: at)
    }

    // MARK: - Composition

    /// Returns the system prompt to send to the model, with action-aware memory
    /// injection. `seedAction` is non-nil for conversation calls; the gating action
    /// is `seedAction ?? action`. The matrix is encoded ONCE here so the call sites
    /// can never disagree about whether a given mode gets voice / facts / exemplars.
    func compose(base: String, for action: Action, seedAction: Action? = nil) -> String {
        let gating = seedAction ?? action
        let injectVoice    = Self.injectsVoice(gating)
        let injectFacts    = Self.injectsFacts(gating)
        let injectExemplar = Self.injectsExemplars(gating)

        // Cold-start gate: no card injection if we don't have one yet.
        let cardEligible = injectVoice && (cached.voiceCard?.isEmpty == false)
        let factsEligible = injectFacts && !cached.facts.isEmpty
        let exemplars = injectExemplar ? loadExemplars() : []

        if !cardEligible && !factsEligible && exemplars.isEmpty { return base }

        var out = base
        if cardEligible, let card = cached.voiceCard {
            out += "\n\nUser writing voice:\n\(card)"
        }
        if factsEligible {
            out += "\n\nFacts about the user:\n" + cached.facts.map { "- \($0)" }.joined(separator: "\n")
        }
        if !exemplars.isEmpty {
            out += "\n\nSamples of the user's own writing (for tone reference only — do NOT copy content):\n---\n"
            out += exemplars.joined(separator: "\n---\n")
            out += "\n---"
        }
        return out
    }

    private func loadExemplars() -> [String] {
        let before = cached.forgottenBefore
        return (try? persistence.dbQueue.read { db in
            try MemoryAttribution.selectExemplars(in: db, forgottenBefore: before,
                                                  limit: Self.exemplarLimit, shuffle: true)
        }) ?? []
    }

    // MARK: - Gating matrix

    /// Voice card injection — see spec §"Injection rules (action-aware)".
    /// Excluded: proofread (no drift), shorter (mechanical). respond and custom
    /// get voice because the user IS the composer being mimicked.
    static func injectsVoice(_ action: Action) -> Bool {
        switch action {
        case .proofread, .shorter: return false
        case .polish, .moreFormal, .moreCasual, .respond, .custom: return true
        }
    }

    /// Facts only where the model composes new content directed at people/projects.
    static func injectsFacts(_ action: Action) -> Bool {
        switch action {
        case .respond, .custom: return true
        default: return false
        }
    }

    static func injectsExemplars(_ action: Action) -> Bool {
        injectsVoice(action)
    }

    // MARK: - Regeneration

    /// Post-commit entry point. Decides (cheaply) whether to schedule a regen.
    /// Single-flight: a second call while a generation is in flight is dropped.
    func interactionDidPersist() {
        guard generationTask == nil else { return }
        if cached.userEdited { return }   // user's hand-tuned profile is ground truth

        Task { [weak self] in
            guard let self else { return }
            let before = self.cached.forgottenBefore
            let eligible = await self.persistence.eligibleInteractionCount(since: before)
            // Cold-start gate (no card under 15 eligible interactions).
            guard eligible >= Self.coldStartGate else { return }
            // Regenerate when grown ≥1.5× since last successful generation.
            // First generation: cached.sampleCount == 0 → threshold is coldStartGate.
            let threshold = max(Self.coldStartGate, Int(Double(self.cached.sampleCount) * Self.regenGrowthFactor))
            guard eligible >= threshold else { return }
            self.scheduleGeneration(eligibleAt: eligible)
        }
    }

    /// Stub. Task 5 fills this with the actual llama-server call. Held single-flight
    /// behind `generationTask`. Overridable for tests (SpyService).
    func scheduleGeneration(eligibleAt: Int) {
        guard generationTask == nil else { return }
        generationTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.generationTask = nil } }
            await self?.runGeneration(eligibleAt: eligibleAt)
        }
    }

    /// Stub. Task 5 implements.
    func runGeneration(eligibleAt: Int) async { /* Task 5 */ }
}
