import Foundation

// TOML-decoded model entry per SWIFTUI-SPEC.md §12.2. Implementation lands in M3.
struct ModelDescriptor {
    let id: String
    let name: String
    let downloadURL: URL
    let downloadSizeBytes: Int64
    let sha256: String
    let contextSize: Int
    let chatTemplate: String
    let isDefault: Bool
    let prompts: [String: String]
    let sampling: SamplingConfig

    struct SamplingConfig {
        let temperature: Double
        let topP: Double
        let repeatPenalty: Double
    }
}
