import Foundation

// TOML-decoded model entry per SWIFTUI-SPEC.md §12.2 / ADR 0005.
// Decoded by ModelRegistry from Bundle's models.toml at boot.
struct ModelDescriptor: Codable, Equatable {
    let id: String
    let name: String
    let downloadURLString: String
    let downloadSizeBytes: Int64
    let sha256: String
    let contextSize: Int
    let isDefault: Bool?
    /// Per-action system-prompt overrides, keyed by `Action.rawValue` (e.g. "proofread",
    /// "more_formal"). A model only needs to supply the actions it wants to override;
    /// anything absent falls back to `ActionPrompts.systemPrompt(for:)`.
    let prompts: [String: String]
    let sampling: Sampling

    var downloadURL: URL? { URL(string: downloadURLString) }

    struct Sampling: Codable, Equatable {
        let temperature: Double
        let topP: Double
        let repeatPenalty: Double

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case repeatPenalty = "repeat_penalty"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sha256, prompts, sampling
        case downloadURLString = "download_url"
        case downloadSizeBytes = "download_size_bytes"
        case contextSize = "context_size"
        case isDefault = "default"
    }
}

struct ModelRegistryDoc: Codable {
    let models: [ModelDescriptor]
}
