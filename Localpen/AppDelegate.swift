import AppKit
import SwiftUI
import ApplicationServices
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let registry = ModelRegistry()
    var persistence: Persistence?

    @Published var firstRunCoordinator: FirstRunCoordinator?

    private var hotkey: HotkeyService?
    private var panelController: PanelController?
    private var llamaServer: LlamaServerController?
    private var firstRunWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var serverStartedForModel: String?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When running under XCTest, skip all launch-time initialization so the
        // test host process doesn't start a llama-server or open windows.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Single-instance guard. Two copies (e.g. the /Applications build and a
        // DerivedData run, or a double-launch from Spotlight) share this bundle
        // id, and each would claim its own menu-bar item + hotkey tap — the
        // duplicate-icon symptom. The already-running instance wins; this newer
        // launch defers and quits before wiring anything up.
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if let existing = others.first {
            log.info("another Localpen instance is already running (pid \(existing.processIdentifier)); quitting this one")
            existing.activate()
            NSApp.terminate(nil)
            return
        }

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

        // MemoryService needs persistence; gracefully nil if Persistence init failed.
        let memory: MemoryService? = persistence.map { MemoryService(persistence: $0, streaming: streaming) }

        // Build the controller first: the presenter's DynamicNotch eagerly builds
        // its content (PanelView(controller:)) during the presenter's init, so the
        // controller must already exist. Then attach the presenter to the controller.
        let panel = PanelController(
            textIO: textIO,
            streaming: streaming,
            persistence: persistence,
            registry: registry,
            llamaServer: server,
            memory: memory,
            openSettings: { [weak self] in self?.openSettings() }
        )
        let notch = NotchPresenter(expanded: { AnyView(PanelView(controller: panel)) })
        panel.attach(notch: notch)
        panelController = panel
        llamaServer = server

        // Wire notch invocation + keyboard back to the controller.
        notch.onHoverOpen = { [weak panel] in panel?.showFromHover() }
        notch.onClickOpen = { [weak panel] in panel?.showFromHover() }
        notch.onClickAway = { [weak panel] in panel?.handleClickAway() }
        notch.handleKey = { [weak panel] event in panel?.handleKeyDown(event) ?? false }
        notch.handleEditorKey = { [weak panel] event in panel?.handleKeyWhileEditing(event) ?? false }

        // Bring up the calm resting notch (compact accent dot) at launch.
        Task { await notch.showIdle() }

        let hk = HotkeyService()
        hk.onFire = { [weak self] in self?.handleHotkey() }
        hk.install()
        hotkey = hk

        let coordinator = FirstRunCoordinator(registry: registry)
        firstRunCoordinator = coordinator

        if coordinator.isComplete {
            startServerIfNeeded()
        } else {
            coordinator.onComplete = { [weak self] in
                self?.firstRunWindow?.close()
                self?.firstRunWindow = nil
                self?.startServerIfNeeded()
            }
            showFirstRunWindow()
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

    // MARK: - Settings window (AppKit-controlled)

    func openSettings() {
        if let existing = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(persistence: persistence)
            .environment(registry)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Localpen Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 320))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
                self.warmUpModel(port: server.port)
            } catch {
                self.log.error("llama-server failed: \(error.localizedDescription)")
            }
        }
    }

    /// Fire one throwaway token through the model right after the server is ready,
    /// so the FIRST real action doesn't pay the cold prompt-eval / graph-setup cost.
    /// We consume a single token then stop (cancelling tears down the request).
    private func warmUpModel(port: Int) {
        let client = StreamingClient(port: port)
        Task.detached(priority: .utility) {
            for try await _ in client.complete(systemPrompt: "Warmup.", userText: "Hi") { break }
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
