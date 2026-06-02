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

    /// Base directory for the user override TOML and the persisted active-model
    /// pointer. Defaults to ~/Library/Application Support/Localpen; injectable so
    /// tests can point at a temp dir and exercise the real persistence round-trip.
    private let supportDirectory: URL

    init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory()
        load()
    }

    var activeModel: ModelDescriptor? {
        models.first { $0.id == activeModelID } ?? models.first
    }

    /// The dedicated curation model (ADR 0015), if one is registered. The dream cycle
    /// brings this up transiently for nightly synthesis; it is never the active
    /// transform model. Resolved by role, not a hardcoded id.
    var curationModel: ModelDescriptor? {
        models.first { $0.isCuration }
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
        case .respond:     return ActionPrompts.systemPrompt(for: .respond(""))
        case .custom:      return ActionPrompts.systemPrompt(for: .custom(""))
        case .ask:         return ActionPrompts.systemPrompt(for: .ask(question: "", withSelection: false))
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

    /// Switch the active model and persist the choice so it survives relaunch.
    /// Model-agnostic (ADR 0005): the id must already be a registered model — the
    /// caller's UI only offers registered models. The persisted pointer is read
    /// back by `load()` on the next launch and takes precedence over the bundled
    /// `default` flag, so a fresh registry resolves the same active model.
    func setActiveModel(id: String) {
        guard models.contains(where: { $0.id == id }) else {
            log.error("setActiveModel ignored: unknown model id \(id, privacy: .public)")
            return
        }
        activeModelID = id
        persistActiveModelID(id)
    }

    private func load() {
        // Bundled baseline
        guard let bundled = Bundle.main.url(forResource: "models", withExtension: "toml"),
              let bundledText = try? String(contentsOf: bundled, encoding: .utf8) else {
            log.error("bundled models.toml not found")
            return
        }

        // Optional user override
        let overrideURL = supportDirectory.appendingPathComponent("models.toml")
        let userOverride: String? = {
            guard FileManager.default.fileExists(atPath: overrideURL.path) else { return nil }
            return try? String(contentsOf: overrideURL, encoding: .utf8)
        }()

        let toml = userOverride ?? bundledText
        do {
            let doc = try TOMLDecoder().decode(ModelRegistryDoc.self, from: toml)
            self.models = doc.models
            // A persisted switch (if it still names a registered model) wins over
            // the bundled `default` flag; otherwise fall back to default → first.
            let persisted = persistedActiveModelID()
            self.activeModelID = persisted.flatMap { id in doc.models.first(where: { $0.id == id })?.id }
                ?? doc.models.first(where: { $0.isDefault == true })?.id
                ?? doc.models.first?.id
                ?? ""
            log.info("loaded \(doc.models.count) model(s); active=\(self.activeModelID, privacy: .public)")
        } catch {
            // Surface the full Codable error chain to Console so we can diagnose schema issues.
            log.error("models.toml decode failed: \(String(describing: error), privacy: .public)")
            fputs("Localpen: models.toml decode failed: \(error)\n", stderr)
        }
    }

    // MARK: - Persisted active-model pointer

    private var activeModelPointerURL: URL {
        supportDirectory.appendingPathComponent("active-model")
    }

    private func persistedActiveModelID() -> String? {
        guard let raw = try? String(contentsOf: activeModelPointerURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistActiveModelID(_ id: String) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try id.write(to: activeModelPointerURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("failed to persist active model id: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultSupportDirectory() -> URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Localpen", isDirectory: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Localpen")
    }
}
