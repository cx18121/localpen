import Foundation
import os

/// The nightly project-activity pass (project-activity-freshness spec): a sibling to the
/// conversation dream cycle. For each project page whose `local_path` is a real git repo, read
/// commits since it went stale → batch → summarize → append to `## Activity`. Best-effort and
/// isolated per project; advances the sync SHA only past successfully-written batches.
struct ProjectActivityPass {
    let index: BrainIndex
    let writer: VaultWriter
    let sync: ProjectSyncStore
    let synthesize: (_ system: String, _ user: String) async -> CurationOutcome
    let now: () -> Date
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Activity")

    struct Report: Equatable { var projects = 0; var entries = 0; var skipped = 0 }

    static func firstRunSince(updatedYMD: String?, now: Date, capDays: Int = 90) -> Date {
        let cap = now.addingTimeInterval(-Double(capDays) * 86400)
        guard let ymd = updatedYMD else { return cap }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let updated = f.date(from: ymd) else { return cap }
        return max(updated, cap)
    }

    func run() async -> Report {
        var report = Report()
        for page in await index.pages(ofType: .project) {
            guard let rawPath = page.frontmatter["local_path"], !rawPath.isEmpty else { continue }
            let repoPath = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: repoPath) else { report.skipped += 1; continue }
            report.projects += 1

            let lastSHA = sync.lastSHA(forRepo: repoPath)
            let sinceDate = lastSHA == nil
                ? Self.firstRunSince(updatedYMD: page.frontmatter["updated"], now: now()) : nil

            let result: GitActivityReader.ReadResult
            do { result = try GitActivityReader.read(repoPath: repoPath, sinceSHA: lastSHA, sinceDate: sinceDate) }
            catch { log.info("activity: skip \(page.title, privacy: .public): \(error.localizedDescription)"); report.skipped += 1; continue }

            let commits = GitActivityReader.substantive(result.commits)
            guard !commits.isEmpty else { sync.record(repo: repoPath, sha: result.head); continue }

            var wroteAny = false
            for batch in ProjectActivityBatcher.batch(commits) {
                guard let entry = await ProjectActivitySynthesis.entry(for: batch, synthesize: synthesize) else { continue }
                do {
                    try writer.apply(.appendActivity(projectTitle: page.title, entry: entry),
                                     nowMillis: Int64(now().timeIntervalSince1970 * 1000))
                    report.entries += 1; wroteAny = true
                } catch { log.info("activity: write failed \(page.title, privacy: .public): \(error.localizedDescription)") }
            }
            // Advance sync to HEAD only if we got through the batches without a write failure
            // mid-way; otherwise leave it so the unwritten commits are retried next run.
            if wroteAny || commits.isEmpty { sync.record(repo: repoPath, sha: result.head) }
        }
        log.info("activity pass: \(report.projects) projects, \(report.entries) entries, \(report.skipped) skipped")
        return report
    }
}
