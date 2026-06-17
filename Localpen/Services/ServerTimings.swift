// Localpen/Services/ServerTimings.swift
import Foundation

/// One llama-server `timings` object, as returned on every `/v1/chat/completions`
/// response (and on each streaming chunk when `timings_per_token: true`). Field
/// names verified against llama.cpp build 9544. `draftN`/`draftNAccepted` appear
/// only when a draft model is loaded (speculative decoding — the
/// `inference-quickwins` branch); they are nil otherwise.
struct ServerTimings: Codable, Equatable {
    let promptN: Int
    let promptMs: Double
    let predictedN: Int
    let predictedMs: Double
    let predictedPerSecond: Double
    let draftN: Int?
    let draftNAccepted: Int?

    enum CodingKeys: String, CodingKey {
        case promptN = "prompt_n"
        case promptMs = "prompt_ms"
        case predictedN = "predicted_n"
        case predictedMs = "predicted_ms"
        case predictedPerSecond = "predicted_per_second"
        case draftN = "draft_n"
        case draftNAccepted = "draft_n_accepted"
    }

    /// Accepted draft tokens / proposed draft tokens. Nil when no draft model is
    /// active (or zero proposals) so callers can distinguish "spec off" from "0%".
    var acceptanceRate: Double? {
        guard let total = draftN, total > 0, let ok = draftNAccepted else { return nil }
        return Double(ok) / Double(total)
    }

    /// Pull `timings` out of an already-deserialized SSE chunk dict. Returns nil if
    /// the chunk carries no timings (content-only chunks, or `[DONE]`).
    static func parse(sseChunkJSON: [String: Any]) -> ServerTimings? {
        guard let timings = sseChunkJSON["timings"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: timings) else { return nil }
        return try? JSONDecoder().decode(ServerTimings.self, from: data)
    }
}
