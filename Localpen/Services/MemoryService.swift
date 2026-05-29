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

    /// Bumped on every externally-driven profile mutation (user save, Forget,
    /// cache refresh). `runGeneration` captures this at start and aborts the
    /// commit if it changed during the long model-streaming await — otherwise a
    /// background regen could clobber a hand-edit that landed mid-generation
    /// (Codex review caught this).
    private(set) var generationEpoch: Int = 0

    /// Post-commit subscription token. Released in deinit.
    private var observer: NSObjectProtocol?

    /// Compose injection thresholds (spec). Held as constants here so tests can pin them.
    static let coldStartGate = 15
    static let regenGrowthFactor = 1.5
    static let exemplarLimit = 5
    static let generationSampleCap = 40

    // MemoryService is @MainActor, which makes static members actor-isolated by default
    // and uncallable from non-@MainActor XCTest cases. The pure helpers below are
    // stateless and safe to call from anywhere — mark them `nonisolated` explicitly.

    nonisolated static let generationSystemPrompt: String = """
        You analyze a user's writing samples and produce a compact voice profile and a \
        conservative list of facts about them. Return STRICT JSON of the form:
        {"voice_card": "...", "facts": ["...", "..."]}
        Rules:
        - voice_card: 150-250 words. Describe concrete, perceptible traits across: tone/register \
          (and how it shifts), formality, typical sentence length & rhythm, vocabulary register, \
          signature words to favor or avoid, punctuation & casing habits, openings/sign-offs, \
          emoji & emphasis usage, contractions/hedging/directness. Do NOT invent traits not \
          evidenced in the samples.
        - facts: short, high-confidence bullets ONLY (name, role if stated, recurring people/\
          projects, hard preferences). If a candidate fact is uncertain, OMIT it. An empty \
          "facts": [] is correct and preferred over speculation.
        - Output ONLY the JSON object, no preamble, no commentary, no code fences.
        """

    nonisolated static func buildGenerationUserPrompt(samples: [MemoryAttribution.Sample]) -> String {
        // Label sources so the model can weight edits highest. Truncate per-sample at 600 chars.
        var s = "Samples (most recent first):\n"
        for sample in samples {
            let label: String = {
                switch sample.source {
                case .userEdit:           return "[edit — user's correction]"
                case .userText:           return "[own writing]"
                case .replySteer:         return "[user's steer on a reply]"
                case .customSteer:        return "[user's instruction]"
                case .conversationTurn:   return "[user's chat turn]"
                }
            }()
            let body = sample.text.count > 600 ? String(sample.text.prefix(600)) + "…" : sample.text
            s += "\n\(label)\n\(body)\n"
        }
        return s
    }

    /// Tolerant JSON parser: strips code fences if the model added them, finds the first
    /// '{' and the matching closing '}', tries to decode. Returns nil on any failure;
    /// callers preserve the previous profile.
    nonisolated static func parseProfileJSON(_ raw: String) -> (voiceCard: String, facts: [String])? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // strip ```json … ``` fence
            if let first = s.range(of: "\n") { s = String(s[first.upperBound...]) }
            if let last = s.range(of: "```", options: .backwards) { s = String(s[..<last.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let openIdx = s.firstIndex(of: "{"),
              let closeIdx = s.lastIndex(of: "}"), closeIdx > openIdx else { return nil }
        let jsonText = String(s[openIdx...closeIdx])
        struct Decoded: Decodable { let voice_card: String; let facts: [String]? }
        guard let data = jsonText.data(using: .utf8),
              let d = try? JSONDecoder().decode(Decoded.self, from: data),
              !d.voice_card.isEmpty else { return nil }
        return (d.voice_card, d.facts ?? [])
    }

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

    /// External mutation (UI edit / Regenerate / Forget) re-syncs the cache and
    /// bumps `generationEpoch` so any in-flight `runGeneration` aborts its commit.
    func saveProfile(_ p: StyleProfile) async {
        generationEpoch &+= 1
        await persistence.saveStyleProfile(p)
        cached = p
    }

    func forget(at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async {
        // `at` is unix-epoch MILLISECONDS to match interactions.timestamp post-v4.
        generationEpoch &+= 1
        await persistence.forgetMemory(at: at)
        cached = StyleProfile(forgottenBefore: at)
    }

    /// Test seam (and the runtime check `runGeneration` calls): a generation
    /// started at `startEpoch` may commit only if no external mutation has
    /// occurred since AND the profile is not user-edited. Either condition flips
    /// the answer to false and the regen aborts without touching the cache.
    func _isGenerationCommitValid(startEpoch: Int) -> Bool {
        generationEpoch == startEpoch && !cached.userEdited
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
    /// Excluded: proofread (no drift), shorter (mechanical). respond, custom, and ask
    /// get voice because the user IS the composer being mimicked.
    static func injectsVoice(_ action: Action) -> Bool {
        switch action {
        case .proofread, .shorter: return false
        case .polish, .moreFormal, .moreCasual, .respond, .custom, .ask: return true
        }
    }

    /// Facts only where the model composes new content directed at people/projects.
    static func injectsFacts(_ action: Action) -> Bool {
        switch action {
        case .respond, .custom, .ask: return true
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

    func runGeneration(eligibleAt: Int) async {
        // Capture epoch at start. A user edit / Forget / saveProfile during the
        // long model-streaming await will bump it; we abort the commit rather
        // than overwrite the user's hand-tuned profile.
        let startEpoch = generationEpoch
        let before = cached.forgottenBefore
        let cap = Self.generationSampleCap   // hoist off MainActor to satisfy Sendable closure
        let samples: [MemoryAttribution.Sample] = (try? await persistence.dbQueue.read { db in
            try MemoryAttribution.collectGenerationSamples(in: db, forgottenBefore: before,
                                                           cap: cap)
        }) ?? []
        guard samples.count >= Self.coldStartGate else {
            log.info("regen aborted: only \(samples.count) eligible samples (< coldStartGate)")
            return
        }

        let userPrompt = Self.buildGenerationUserPrompt(samples: samples)
        var raw = ""
        do {
            for try await tok in streaming.complete(systemPrompt: Self.generationSystemPrompt,
                                                    userText: userPrompt) {
                raw += tok
            }
        } catch {
            log.error("regen streaming failed: \(error.localizedDescription)")
            return   // keep previous profile
        }

        guard _isGenerationCommitValid(startEpoch: startEpoch) else {
            log.info("regen aborted at commit: profile mutated or marked user-edited during generation")
            return
        }

        guard let parsed = Self.parseProfileJSON(raw) else {
            log.error("regen JSON parse failed; keeping previous profile")
            return
        }

        var next = cached
        next.voiceCard = parsed.voiceCard
        next.facts = parsed.facts
        next.generatedAt = Int64(Date().timeIntervalSince1970 * 1000)  // ms (post-v4 invariant)
        // sampleCount = the basis the profile was actually built from, NOT raw
        // eligibleAt. With generationSampleCap=40 and 100 eligible rows, the profile
        // is built from 40 samples; recording 100 would delay the next regen to 150
        // eligible (1.5×) and leave the profile stale after substantial new data.
        next.sampleCount = samples.count
        next.userEdited = false
        // Write through saveProfile so the epoch bumps consistently with every
        // other commit path — without that, callers polling `generationEpoch`
        // would miss this transition.
        await saveProfile(next)
        log.info("regen committed: \(parsed.voiceCard.count) chars, \(parsed.facts.count) facts, basis=\(samples.count)")
    }
}
