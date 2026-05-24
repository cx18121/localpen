import AppKit
import SwiftUI
import ApplicationServices
import os

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var firstRunCoordinator: FirstRunCoordinator?
    @Published var registry: ModelRegistry?
    var persistence: Persistence?

    private var hotkey: HotkeyService?
    private var panelController: PanelController?
    private var llamaServer: LlamaServerController?
    private var anchorStore: AnchorStore?
    private var firstRunWindow: NSWindow?
    private var serverStartedForModel: String?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "App")

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        HardwareFingerprint.collectAndPersistIfNeeded()

        persistence = try? Persistence()

        let registry = ModelRegistry()
        self.registry = registry

        let anchorStore = AnchorStore()
        self.anchorStore = anchorStore

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
        panelController = panel
        llamaServer = server

        let hk = HotkeyService()
        hk.onFire = { [weak self] in self?.handleHotkey() }
        hk.install()
        hotkey = hk

        let coordinator = FirstRunCoordinator(registry: registry)
        firstRunCoordinator = coordinator

        if coordinator.isComplete {
            startServerIfNeeded()
        } else {
            showFirstRunWindow()
            observeFirstRunCompletion()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        llamaServer?.stop()
    }

    // MARK: - First-run window

    @MainActor private func showFirstRunWindow() {
        guard let coordinator = firstRunCoordinator, firstRunWindow == nil else { return }

        let host = NSHostingController(rootView: FirstRunView(coordinator: coordinator))
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to Localpen"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 320))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        firstRunWindow = window
    }

    @MainActor private func observeFirstRunCompletion() {
        Task { @MainActor in
            guard let coordinator = firstRunCoordinator else { return }
            while !coordinator.isComplete {
                try? await Task.sleep(for: .milliseconds(300))
            }
            firstRunWindow?.close()
            firstRunWindow = nil
            startServerIfNeeded()
        }
    }

    // MARK: - Server

    @MainActor private func startServerIfNeeded() {
        guard let registry, let server = llamaServer, let descriptor = registry.activeModel else { return }
        if serverStartedForModel == descriptor.id, case .ready = server.state { return }
        serverStartedForModel = descriptor.id

        let modelPath = registry.modelPath(for: descriptor).path
        Task { @MainActor in
            do {
                try await server.start(modelPath: modelPath)
                self.log.info("llama-server ready on port \(server.port)")
            } catch {
                self.log.error("llama-server failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hotkey

    @MainActor private func handleHotkey() {
        guard let coordinator = firstRunCoordinator, coordinator.isComplete else {
            firstRunWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        panelController?.toggleFromHotkey()
    }

    @MainActor func openPanel() {
        handleHotkey()
    }
}
