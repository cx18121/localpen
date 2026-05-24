import AppKit
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyService?
    private var panelController: PanelController?
    private var llamaServer: LlamaServerController?
    private var persistence: Persistence?
    private var registry: ModelRegistry?
    private var anchorStore: AnchorStore?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "App")

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // AX permission (M4 will route into a proper FirstRun flow).
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        log.info("AX trusted at launch: \(trusted)")

        // Hardware fingerprint — collect once on first launch.
        HardwareFingerprint.collectAndPersistIfNeeded()

        // Persistence (best-effort: failures don't block the app).
        let persistence = try? Persistence()
        self.persistence = persistence

        // Model registry.
        let registry = ModelRegistry()
        self.registry = registry

        // Anchor store.
        let anchorStore = AnchorStore()
        self.anchorStore = anchorStore

        // Services.
        let textIO = TextIO()
        let server = LlamaServerController()
        let streaming = StreamingClient(port: server.port)
        let panel = PanelController(
            textIO: textIO,
            streaming: streaming,
            persistence: persistence,
            registry: registry,
            anchorStore: anchorStore
        )
        self.panelController = panel
        self.llamaServer = server

        let hk = HotkeyService()
        hk.onFire = { [weak panel] in panel?.toggleFromHotkey() }
        hk.install()
        self.hotkey = hk

        // Boot the model server. Use the active model's resolved on-disk path.
        let modelPath: String = {
            if let descriptor = registry.activeModel {
                return registry.modelPath(for: descriptor).path
            }
            // Fallback for first-run before registry loaded a default.
            return ("~/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf" as NSString)
                .expandingTildeInPath
        }()

        Task { @MainActor in
            do {
                try await server.start(modelPath: modelPath)
                self.log.info("llama-server ready on port \(server.port)")
            } catch {
                self.log.error("llama-server failed: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        llamaServer?.stop()
    }
}
