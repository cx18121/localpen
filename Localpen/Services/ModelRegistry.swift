import Foundation
import TOMLKit
import os

// TOML model registry per SWIFTUI-SPEC.md §12 / ADR 0005.
// Loads bundled models.toml, overlays user override at ~/Library/Application Support/Localpen/models.toml.
@MainActor
@Observable
final class ModelRegistry {
    private(set) var models: [ModelDescriptor] = []
    private(set) var activeModelID: String = ""
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ModelRegistry")

    init() {
        load()
    }

    var activeModel: ModelDescriptor? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    func systemPrompt(for action: Action) -> String {
        guard let model = activeModel else {
            return ActionPrompts.systemPrompt(for: action)
        }
        switch action {
        case .proofread:   return model.prompts.proofread
        case .polish:      return model.prompts.polish
        case .moreFormal:  return model.prompts.moreFormal
        case .moreCasual:  return model.prompts.moreCasual
        case .shorter:     return model.prompts.shorter
        case .custom:      return ActionPrompts.systemPrompt(for: .custom(""))
        }
    }

    func modelPath(for descriptor: ModelDescriptor) -> URL {
        Self.modelsDirectory().appendingPathComponent("\(descriptor.id).gguf")
    }

    static func modelsDirectory() -> URL {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Localpen/models", isDirectory: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Localpen/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func load() {
        // Bundled baseline
        guard let bundled = Bundle.main.url(forResource: "models", withExtension: "toml"),
              let bundledText = try? String(contentsOf: bundled, encoding: .utf8) else {
            log.error("bundled models.toml not found")
            return
        }

        // Optional user override
        let userOverride: String? = {
            let url = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ))?.appendingPathComponent("Localpen/models.toml")
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }()

        let toml = userOverride ?? bundledText
        do {
            let doc = try TOMLDecoder().decode(ModelRegistryDoc.self, from: toml)
            self.models = doc.models
            self.activeModelID = doc.models.first(where: { $0.isDefault == true })?.id
                ?? doc.models.first?.id
                ?? ""
            log.info("loaded \(doc.models.count) model(s); active=\(self.activeModelID, privacy: .public)")
        } catch {
            log.error("models.toml decode failed: \(error.localizedDescription)")
        }
    }
}
