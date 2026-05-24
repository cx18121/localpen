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
    let chatTemplate: String
    let isDefault: Bool?
    let prompts: Prompts
    let sampling: Sampling

    var downloadURL: URL? { URL(string: downloadURLString) }

    struct Prompts: Codable, Equatable {
        let proofread: String
        let polish: String
        let moreFormal: String
        let moreCasual: String
        let shorter: String

        enum CodingKeys: String, CodingKey {
            case proofread, polish, shorter
            case moreFormal = "more_formal"
            case moreCasual = "more_casual"
        }
    }

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
        case chatTemplate = "chat_template"
        case isDefault = "default"
    }
}

struct ModelRegistryDoc: Codable {
    let models: [ModelDescriptor]
}
