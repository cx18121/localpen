import Foundation

/// Splits chronological commits into bounded batches so each activity summary stays accurate
/// (count cap) and temporally honest (span cap). Pure + total.
struct ActivityBatch: Equatable { let commits: [Commit] }

enum ProjectActivityBatcher {
    static func batch(_ commits: [Commit], maxCount: Int = 30, maxSpanDays: Int = 14) -> [ActivityBatch] {
        guard !commits.isEmpty else { return [] }
        var out: [ActivityBatch] = []
        var cur: [Commit] = []
        let spanSec = TimeInterval(maxSpanDays) * 86400
        for c in commits {
            if let first = cur.first,
               (cur.count >= maxCount || c.date.timeIntervalSince(first.date) > spanSec) {
                out.append(ActivityBatch(commits: cur))
                cur = []
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(ActivityBatch(commits: cur)) }
        return out
    }
}
