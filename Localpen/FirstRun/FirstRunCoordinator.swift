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

    /// Fired once when first-run reaches `.ready`. The owner uses it to close
    /// the first-run window and start the server — replacing a polling loop.
    @ObservationIgnored var onComplete: (@MainActor () -> Void)?

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
            Task { @MainActor in self?.recheckPermission() }
        }
    }

    deinit {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Determines the initial step. Safe to call only when no operation is in
    /// flight (i.e. at init, or from `recheckPermission` while on `.permission`).
    /// Does NOT auto-start the download — it just surfaces the download prompt;
    /// the user clicks "Download" to begin (ADR 0002).
    func evaluate() {
        if !isAXTrusted() {
            step = .permission
            return
        }
        if !isModelInstalled() {
            step = .downloading(bytesDone: 0, bytesTotal: registry.activeModel?.downloadSizeBytes ?? 0)
            return
        }
        markReady()
    }

    /// Bound to app reactivation (user returning from System Settings after
    /// granting Accessibility). Only ever advances *out of* `.permission`, so
    /// it can never clobber an in-flight download, a download error, or ready.
    func recheckPermission() {
        guard step == .permission else { return }
        evaluate()
    }

    private func markReady() {
        step = .ready
        onComplete?()
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

        // Disk-full pre-check (M6.5): require model size + 100MB headroom.
        let available = HardwareFingerprint.collect().freeDiskBytes
        let required = descriptor.downloadSizeBytes + 100_000_000
        if available < required {
            let neededGB = Double(required) / 1_073_741_824
            let availableGB = Double(available) / 1_073_741_824
            step = .downloadError(String(format: "Not enough space — need %.1f GB, have %.1f GB.", neededGB, availableGB))
            return
        }

        guard let url = descriptor.downloadURL else {
            step = .downloadError("Invalid download URL for \(descriptor.id)")
            return
        }
        let dest = registry.modelPath(for: descriptor)
        step = .downloading(bytesDone: 0, bytesTotal: descriptor.downloadSizeBytes)
        do {
            try await downloader.download(from: url, to: dest) { [weak self] p in
                self?.step = .downloading(bytesDone: p.bytesDone, bytesTotal: p.bytesTotal)
            }
            markReady()
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
