import Foundation
import GRDB

/// The single evolving memory row. id is always 1; we upsert.
/// `forgottenBefore` is the durable-forget tombstone: profile generation and exemplar
/// selection MUST filter out interactions with `timestamp < forgottenBefore`. Clearing
/// the card without bumping this would let the next regeneration resurrect the same
/// content from the same source rows — the loophole the spec calls out.
struct StyleProfile: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    var id: Int64 = 1
    var voiceCard: String?
    /// JSON-encoded `[String]` in storage; in memory always a Swift array.
    /// (We codec the JSON ourselves rather than relying on GRDB's column codec
    /// because the column type is TEXT and we want explicit empty-array semantics.)
    var facts: [String] = []
    var generatedAt: Int64?
    var sampleCount: Int = 0
    var userEdited: Bool = false
    var forgottenBefore: Int64 = 0

    static let databaseTableName = "style_profile"

    enum CodingKeys: String, CodingKey {
        case id
        case voiceCard = "voice_card"
        case factsJSON = "facts"
        case generatedAt = "generated_at"
        case sampleCount = "sample_count"
        case userEdited = "user_edited"
        case forgottenBefore = "forgotten_before"
    }

    init(id: Int64 = 1, voiceCard: String? = nil, facts: [String] = [],
         generatedAt: Int64? = nil, sampleCount: Int = 0,
         userEdited: Bool = false, forgottenBefore: Int64 = 0) {
        self.id = id; self.voiceCard = voiceCard; self.facts = facts
        self.generatedAt = generatedAt; self.sampleCount = sampleCount
        self.userEdited = userEdited; self.forgottenBefore = forgottenBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 1
        voiceCard = try c.decodeIfPresent(String.self, forKey: .voiceCard)
        let raw = try c.decodeIfPresent(String.self, forKey: .factsJSON) ?? "[]"
        facts = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        generatedAt = try c.decodeIfPresent(Int64.self, forKey: .generatedAt)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        userEdited = try c.decodeIfPresent(Bool.self, forKey: .userEdited) ?? false
        forgottenBefore = try c.decodeIfPresent(Int64.self, forKey: .forgottenBefore) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(voiceCard, forKey: .voiceCard)
        let data = (try? JSONEncoder().encode(facts)) ?? Data("[]".utf8)
        try c.encode(String(data: data, encoding: .utf8) ?? "[]", forKey: .factsJSON)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(userEdited, forKey: .userEdited)
        try c.encode(forgottenBefore, forKey: .forgottenBefore)
    }
}
