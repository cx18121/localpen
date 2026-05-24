import AppKit
import SwiftUI
import ApplicationServices
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Initialized at property declaration so SwiftUI bodies that read these
    // never see a transient nil during launch. (Previously: race between
    // applicationDidFinishLaunching populating registry and the Settings
    // scene's body being first evaluated.)
    let registry = ModelRegistry()
    let anchorStore = AnchorStore()
    var persistence: Persistence?

    @Published var firstRunCoordinator: FirstRunCoordinator?

    private var hotkey: HotkeyService?
    private var panelController: PanelController?
    private var llamaServer: LlamaServerController?
    private var firstRunWindow: NSWindow?
    private var serverStartedForModel: String?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        HardwareFingerprint.collectAndPersistIfNeeded()

        do {
            persistence = try Persistence()
        } catch {
            log.error("Persistence init failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Localpen couldn't open its history database."
            alert.informativeText = "\(error.localizedDescription)\n\nLocalpen will run, but interactions won't be saved (ADR 0006). Check disk permissions on ~/Library/Application Support/Localpen/."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.runModal()
            persistence = nil
        }

        let textIO = TextIO()
        let server = LlamaServerController()
        let streaming = StreamingClient(port: server.port)
        let panel = PanelController(
            textIO: textIO,
            streaming: streaming,
            persistence: persistence,
            registry: registry,
            anchorStore: anchorStore,
            llamaServer: server
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

    private func showFirstRunWindow() {
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

    private func observeFirstRunCompletion() {
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

    private func startServerIfNeeded() {
        guard let server = llamaServer, let descriptor = registry.activeModel else { return }
        if serverStartedForModel == descriptor.id, case .ready = server.state { return }
        serverStartedForModel = descriptor.id

        let modelPath = registry.modelPath(for: descriptor).path
        Task { @MainActor in
            do {
                try await server.start(modelPath: modelPath, contextSize: descriptor.contextSize)
                self.log.info("llama-server ready on port \(server.port)")
            } catch {
                self.log.error("llama-server failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hotkey

    private func handleHotkey() {
        guard let coordinator = firstRunCoordinator, coordinator.isComplete else {
            firstRunWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let server = llamaServer, server.isReady else {
            log.info("hotkey ignored — llama-server not ready yet")
            NSSound.beep()
            return
        }
        panelController?.toggleFromHotkey()
    }

    func openPanel() {
        handleHotkey()
    }
}
