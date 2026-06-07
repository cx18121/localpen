import Foundation

/// Reciprocal Rank Fusion: combine ranked lists by *rank position*, sidestepping the
/// BM25-score vs cosine-score incompatibility. score(item) = Σ 1/(k + rank_i).
enum RankFusion {
    /// `lists` are each ranked best-first (by id). Returns ids ordered by fused score desc.
    static func rrf(_ lists: [[String]], k: Double) -> [String] {
        var score: [String: Double] = [:]
        for list in lists {
            for (idx, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / (k + Double(idx + 1))
            }
        }
        return score.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key   // stable tiebreak
        }.map(\.key)
    }
}
