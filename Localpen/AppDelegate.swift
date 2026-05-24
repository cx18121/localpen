import AppKit
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyService?
    private var panelController: PanelController?
    private var llamaServer: LlamaServerController?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "App")

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // M1.4 prerequisite: AX permission. M4 will route into a proper FirstRun flow.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        log.info("AX trusted at launch: \(trusted)")

        let textIO = TextIO()
        let server = LlamaServerController()
        let streaming = StreamingClient(port: server.port)
        let panel = PanelController(textIO: textIO, streaming: streaming)
        let hk = HotkeyService()
        hk.onFire = { [weak panel] in panel?.toggleFromHotkey() }
        hk.install()

        self.hotkey = hk
        self.panelController = panel
        self.llamaServer = server

        let modelPath = ("~/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf" as NSString).expandingTildeInPath
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
