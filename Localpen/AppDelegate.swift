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
    private var brainIndex: BrainIndex?
    private var brainWatcher: KBWatcher?
    private var conversationStash: ConversationStash?
    private var suggestionStore: SuggestionStore?
    private var dreamCycleTimer: Timer?
    private var dreamCycleRunning = false
    private var firstRunWindow: NSWindow?
    private var settingsWindowController: SettingsWindowController?
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

        let contextProbe = ContextProbe()

        // Brain index (ADR 0014): a derived FTS5 index over the Obsidian vault. Optional —
        // nil if brain.sqlite can't open. ContextEngine self-gates on BrainAccess.isActive,
        // so injecting it always is safe (off ⇒ byte-identical ask prompt).
        let brainIndex = try? BrainIndex()
        self.brainIndex = brainIndex
        let contextEngine = brainIndex.map { ContextEngine(search: KBSearch(dbQueue: $0.dbQueue), index: $0) }

        // Curation (ADR 0015): the hot-path stash + the high-judgment suggestion queue.
        // Both are Localpen-private dirs; harmless if they fail to open (nil ⇒ no curation).
        let conversationStash = try? ConversationStash()
        self.conversationStash = conversationStash
        let suggestionStore = try? SuggestionStore()
        self.suggestionStore = suggestionStore

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
            contextProbe: contextProbe,
            contextEngine: contextEngine,
            brainIndex: brainIndex,
            conversationStash: conversationStash,
            suggestionStore: suggestionStore,
            openSettings: { [weak self] in self?.settingsWindowController?.show() }
        )
        settingsWindowController = SettingsWindowController(
            registry: registry, persistence: persistence,
            switchModel: { [weak self] id in self?.switchModel(id: id) })
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

        // Warm the calendar-context cache at launch so the first ask's chip is
        // populated (ADR 0013). No-op unless the user enabled it + set a feed URL.
        CalendarAccess.refreshNow()

        // Build/refresh the brain index + watch the vault — only when opted in (ADR
        // 0014/0015 gate). Also re-run when the user flips the Settings toggle live.
        refreshBrain()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshBrain),
                                               name: .brainConfigChanged, object: nil)

        // Nightly dream cycle (ADR 0015) + a manual "Run curation now" trigger from Settings.
        scheduleDreamCycle()
        NotificationCenter.default.addObserver(self, selector: #selector(runDreamCycleNow),
                                               name: .runDreamCycleNow, object: nil)

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

    /// (Re)index the vault + start the watcher when the brain is enabled; tear the
    /// watcher down when disabled. Idempotent — safe to call at launch and on every
    /// Settings change (ADR 0014/0015 opt-in gate). Off ⇒ we never read the vault.
    @objc private func refreshBrain() {
        guard let brainIndex, BrainAccess.isActive else {
            brainWatcher?.stop(); brainWatcher = nil; return
        }
        let root = BrainAccess.vaultRoot
        Task.detached { await brainIndex.reindexAll(root: root) }
        if brainWatcher == nil {
            let watcher = KBWatcher(index: brainIndex)
            watcher.start()
            brainWatcher = watcher
        }
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

    /// Switch the active model from Settings, staged so a failed load can't strand
    /// the user. The naïve path persisted the new model and stopped the working
    /// server BEFORE proving the new model starts — a corrupt GGUF / timeout / port
    /// conflict then left a dead server and a persisted pointer at the broken model
    /// across relaunch (Codex [high]). `ModelSwitcher` stops the old server, starts
    /// the NEW model, and only commits the active-model pointer once it's ready; on
    /// failure it restarts the previous model and surfaces a visible error instead
    /// of only logging.
    func switchModel(id: String) {
        guard id != registry.activeModelID else { return }
        guard let server = llamaServer,
              let candidate = registry.models.first(where: { $0.id == id }),
              let previous = registry.activeModel else { return }

        let candidateStage = ModelSwitcher.ModelStage(
            id: candidate.id,
            path: registry.modelPath(for: candidate).path,
            contextSize: candidate.contextSize
        )
        let previousStage = ModelSwitcher.ModelStage(
            id: previous.id,
            path: registry.modelPath(for: previous).path,
            contextSize: previous.contextSize
        )

        let switcher = ModelSwitcher(
            start: { path, ctx in try await server.start(modelPath: path, contextSize: ctx) },
            stop: { server.stop() },
            commit: { [weak self] newID in self?.registry.setActiveModel(id: newID) }
        )

        Task { @MainActor in
            let outcome = await switcher.switchTo(candidate: candidateStage, previous: previousStage)
            switch outcome {
            case .switched(let newID):
                // Mark which model the running server now serves so a later
                // startServerIfNeeded() doesn't needlessly respawn it.
                self.serverStartedForModel = newID
                self.log.info("llama-server ready on new model \(newID, privacy: .public)")
                self.warmUpModel(port: server.port)
            case .failed(let newID, let previousID, let message, let previousRestored):
                self.serverStartedForModel = previousRestored ? previousID : nil
                self.log.error("model switch to \(newID, privacy: .public) failed: \(message, privacy: .public)")
                self.presentModelSwitchFailure(newID: newID, message: message, previousRestored: previousRestored)
            }
        }
    }

    /// Visible failure surface for a model switch that couldn't start the new
    /// model — the Settings model picker is the user's last touchpoint, so an
    /// alert there is the honest place to say "that didn't work" rather than
    /// burying it in Console.
    private func presentModelSwitchFailure(newID: String, message: String, previousRestored: Bool) {
        let alert = NSAlert()
        alert.messageText = "Couldn't switch to that model."
        alert.informativeText = previousRestored
            ? "\(newID) failed to start (\(message)). Your previous model is still active."
            : "\(newID) failed to start (\(message)), and the previous model couldn't be restarted. Try switching again or restart Localpen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    // MARK: - Dream cycle (ADR 0015)

    private static let dreamCycleLastRunKey = "curation.lastRunMillis"

    /// Poll every 30 min; `maybeRunDreamCycle` self-gates on the off-peak window + a
    /// once-a-day floor, so the cycle only fires while the user is likely asleep.
    private func scheduleDreamCycle() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maybeRunDreamCycle() }
        }
        timer.tolerance = 300
        dreamCycleTimer = timer
    }

    @objc private func runDreamCycleNow() { runDreamCycle(force: true) }

    private func maybeRunDreamCycle() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard (2..<6).contains(hour) else { return }                       // off-peak only
        let last = UserDefaults.standard.double(forKey: Self.dreamCycleLastRunKey)
        let nowMs = Date().timeIntervalSince1970 * 1000
        guard nowMs - last > 18 * 3600 * 1000 else { return }              // at most ~once/day
        runDreamCycle(force: false)
    }

    /// Build + run one dream cycle. `force` (the manual Settings trigger) bypasses the
    /// schedule gate but still respects the brain toggle and the model being present.
    private func runDreamCycle(force: Bool) {
        // Fail loud: every reason a manual run can't proceed is reported back to Settings,
        // so the button never just does nothing.
        guard !dreamCycleRunning else { dreamFinished(force, "Curation is already running.") ; return }
        guard BrainAccess.isActive else { dreamFinished(force, "Turn on the knowledge base in Settings first.") ; return }
        guard let server = llamaServer,
              let stash = conversationStash,
              let suggestions = suggestionStore else {
            dreamFinished(force, "Curation isn't ready (model registry didn't load)."); return
        }

        dreamCycleRunning = true
        if force { NotificationCenter.default.post(name: .dreamCycleStarted, object: nil) }

        // ADR 0017: synthesis runs against the already-loaded transform model. The runner
        // owns the synthesis policy; this method owns only the run flag, the timestamp, the
        // reindex, and reporting back to Settings.
        let runner = DreamCycleRunner(
            server: server, stash: stash, suggestions: suggestions,
            nowMillis: { Int64(Date().timeIntervalSince1970 * 1000) }
        )

        Task { @MainActor in
            let report = await runner.run()
            self.dreamCycleRunning = false
            UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: Self.dreamCycleLastRunKey)
            self.log.info("dream cycle: applied \(report.applied) queued \(report.queued) failed \(report.failed) note=\(report.note, privacy: .public)")
            // New vault pages should become searchable immediately.
            if report.applied > 0, let brainIndex = self.brainIndex {
                let root = BrainAccess.vaultRoot
                Task.detached { await brainIndex.reindexAll(root: root) }
            }
            self.dreamFinished(force, report.summaryLine)
        }
    }

    /// Report a dream-cycle outcome to the Settings UI (clears its "curating…" state). Only
    /// for manual (`force`) runs — the nightly run has no open UI. Does NOT touch
    /// `dreamCycleRunning` (the run that owns it resets it), so the "already running" guard
    /// can call this without clobbering the in-flight run's state.
    private func dreamFinished(_ force: Bool, _ message: String) {
        log.info("dream cycle: \(message, privacy: .public)")
        if force {
            NotificationCenter.default.post(name: .dreamCycleFinished, object: nil,
                                            userInfo: ["message": message])
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
            log.info("hotkey before llama-server ready — showing warming-up beat")
            panelController?.showWarmingUp()
            return
        }
        panelController?.toggleFromHotkey()
    }

    func openPanel() {
        handleHotkey()
    }

    /// Menu-bar "Settings…" entry point — forwards to the dedicated window controller.
    func showSettings() {
        settingsWindowController?.show()
    }
}
