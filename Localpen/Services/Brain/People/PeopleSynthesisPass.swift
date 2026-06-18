import Foundation
import os

/// The people-synthesis pass: for each `people/` page with raw connection bullets,
/// distill a 2-4 sentence Compiled Truth and a deduped bullet list. Hash-gated so a
/// page is only re-synthesized when its bullets change. Best-effort and isolated per
/// person — one bad page never aborts the pass.
struct PeopleSynthesisPass {
    let index: BrainIndex
    let writer: VaultWriter
    let store: PeopleSynthStore
    let synthesize: (_ system: String, _ user: String) async -> CurationOutcome
    let now: () -> Date
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "PeopleSynth")

    struct Report: Equatable { var people = 0; var synthesized = 0; var skipped = 0 }

    func run() async -> Report {
        var report = Report()
        for page in await index.pages(ofType: .person) {
            let conns = PeopleSynthesis.connections(in: page.body)
            guard !conns.isEmpty else { report.skipped += 1; continue }
            report.people += 1

            let fp = PeopleSynthesis.fingerprint(conns)
            if fp == store.lastFingerprint(forPath: page.path) { continue }

            let system = PeopleSynthesis.system
            let user   = PeopleSynthesis.prompt(name: page.title, connections: conns)
            let outcome = await synthesize(system, user)

            switch outcome {
            case .completed(let text):
                guard let parsed = PeopleSynthesis.parse(text) else {
                    log.info("people-synth: parse failed for \(page.title, privacy: .public)")
                    continue
                }
                do {
                    try writer.apply(
                        .synthesizePerson(name: page.title,
                                          compiledTruth: parsed.compiledTruth,
                                          connections: parsed.connections),
                        nowMillis: Int64(now().timeIntervalSince1970 * 1000)
                    )
                    store.record(path: page.path, fingerprint: fp)
                    report.synthesized += 1
                } catch {
                    log.info("people-synth: write failed \(page.title, privacy: .public): \(error.localizedDescription)")
                }
            case .failed(let reason):
                log.info("people-synth: model failed \(page.title, privacy: .public): \(reason, privacy: .public)")
            }
        }
        log.info("people-synth pass: \(report.people) people, \(report.synthesized) synthesized, \(report.skipped) skipped")
        return report
    }
}
