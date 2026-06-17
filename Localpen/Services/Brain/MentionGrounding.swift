import Foundation

/// Formats grounding for a resolved mention (W2): a one-line orientation header + cosine-ranked
/// chunk selection. Pure so ranking/formatting are unit-testable without a DB or server.
enum MentionGrounding {
    static func personHeader(_ p: PeopleInsights.Person) -> String? {
        var parts = ["\(p.tier) tier"]
        if let d = p.daysSinceContact { parts.append("last contact \(d)d ago") }
        if let f = p.followUp { parts.append("follow-up: \(f)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func projectHeader(_ page: KBPage) -> String? {
        let fields = ["status", "stage"].compactMap { key -> String? in
            PeopleInsights.cleaned(page.frontmatter[key]).map { "\(key): \($0)" }
        }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    static func rankChunks(_ chunks: [ChunkStore.ChunkRow], queryVector: [Float], limit: Int) -> [ChunkStore.ChunkRow] {
        chunks
            .map { (row: $0, sim: VectorMath.cosine(queryVector, $0.vector)) }
            .sorted { $0.sim > $1.sim }
            .prefix(limit)
            .map(\.row)
    }
}
