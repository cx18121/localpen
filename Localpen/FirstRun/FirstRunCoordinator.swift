import Foundation
import AppKit
import ApplicationServices
import Observation
import os

@MainActor
@Observable
final class FirstRunCoordinator {
    enum Step: Equatable {
        case permission
        case downloading(bytesDone: Int64, bytesTotal: Int64)
        case downloadError(String)
        case ready
    }

    var step: Step = .permission
    var isComplete: Bool { step == .ready }

    @ObservationIgnored private let registry: ModelRegistry
    @ObservationIgnored private let downloader = ModelDownloader()
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "FirstRun")
    @ObservationIgnored private var activationObserver: Any?

    init(registry: ModelRegistry) {
        self.registry = registry
        evaluate()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    deinit {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func evaluate() {
        if !isAXTrusted() {
            step = .permission
            return
        }
        if !isModelInstalled() {
            // Don't auto-start: let the user click "Download" so it's explicit.
            if case .downloading = step { return }
            if case .downloadError = step { return }
            step = .downloading(bytesDone: 0, bytesTotal: registry.activeModel?.downloadSizeBytes ?? 0)
            return
        }
        step = .ready
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func startDownload() async {
        guard let descriptor = registry.activeModel else {
            step = .downloadError("No active model configured")
            return
        }
        let dest = registry.modelPath(for: descriptor)
        step = .downloading(bytesDone: 0, bytesTotal: descriptor.downloadSizeBytes)
        do {
            try await downloader.download(from: descriptor.downloadURL, to: dest) { [weak self] p in
                self?.step = .downloading(bytesDone: p.bytesDone, bytesTotal: p.bytesTotal)
            }
            step = .ready
        } catch {
            log.error("download failed: \(error.localizedDescription)")
            step = .downloadError(error.localizedDescription)
        }
    }

    func cancelDownload() {
        downloader.cancel()
    }

    // MARK: - Probes

    private func isAXTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func isModelInstalled() -> Bool {
        guard let descriptor = registry.activeModel else { return false }
        return FileManager.default.fileExists(atPath: registry.modelPath(for: descriptor).path)
    }
}
