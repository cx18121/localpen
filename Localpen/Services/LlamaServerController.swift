import Foundation
import Darwin
import os

@MainActor
final class LlamaServerController {
    enum ServerState {
        case stopped
        case starting
        case ready
        case crashed(String)
    }

    let port: Int = 11434
    private(set) var state: ServerState = .stopped
    private var process: Process?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "LlamaServer")

    func start(modelPath: String, contextSize: Int = 4096) async throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw NSError(domain: "Localpen", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "Model file not found at \(modelPath)"])
        }
        guard let binaryURL = Bundle.main.url(forResource: "llama-server", withExtension: nil) else {
            throw NSError(domain: "Localpen", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "llama-server binary not in bundle Resources"])
        }

        // Clear any llama-server leaked by a prior run before we spawn + bind.
        // `stop()` covers clean termination, but a crash / force-quit / Xcode-stop
        // orphans the child; it then squats port 11434 so our fresh spawn can't
        // bind, leaving `state` non-ready and every hotkey beeping via
        // AppDelegate's isReady guard. Done here (not just at launch) so a restart
        // also starts from a clean port.
        await reapOrphanedServers(binaryPath: binaryURL.path)

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--ctx-size", "\(contextSize)",
            "--n-gpu-layers", "999",
            "--mlock"
        ]

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("llama-server.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()
        proc.standardOutput = handle
        proc.standardError = handle

        try proc.run()
        process = proc
        state = .starting
        log.info("llama-server pid=\(proc.processIdentifier) starting on port \(self.port)")

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            // Verify our process is still alive BEFORE accepting the health response —
            // otherwise a foreign service on port 11434 (e.g., Ollama) could be
            // accepted as our llama-server.
            if !proc.isRunning {
                state = .crashed("exited before health check")
                throw NSError(domain: "Localpen", code: 102,
                              userInfo: [NSLocalizedDescriptionKey: "llama-server exited before becoming healthy"])
            }
            if await isHealthy() {
                state = .ready
                return
            }
        }
        state = .crashed("health check timed out")
        throw NSError(domain: "Localpen", code: 103,
                      userInfo: [NSLocalizedDescriptionKey: "llama-server didn't become healthy in 20s"])
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    /// Whether the server is currently in the `.ready` state.
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// SIGTERM (then SIGKILL) any llama-server spawned from our exact bundled
    /// path that ISN'T the process we currently own, then wait until they exit
    /// so the port is free before we bind. Matching on the full bundled path
    /// means a foreign server (Ollama, a different-location dev build) is never
    /// touched; excluding our own pid means a restart never kills its successor.
    private func reapOrphanedServers(binaryPath: String) async {
        let ownPID = process?.processIdentifier
        func orphans() -> [pid_t] { pgrepPIDs(matching: binaryPath).filter { $0 != ownPID } }

        let initial = orphans()
        guard !initial.isEmpty else { return }
        log.info("reaping \(initial.count) orphaned llama-server(s) from a prior run")
        for pid in initial { kill(pid, SIGTERM) }

        // Wait for them to exit (and release the port) before returning.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if orphans().isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Still alive after SIGTERM — escalate so our bind doesn't fail.
        for pid in orphans() {
            log.error("orphaned llama-server pid=\(pid) ignored SIGTERM; sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    /// PIDs whose full command line matches `pattern`, via `/usr/bin/pgrep -f`.
    /// Returns [] on any failure — reaping is best-effort.
    private func pgrepPIDs(matching pattern: String) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", pattern]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        } catch {
            return []
        }
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            // Defence-in-depth: only trust the health response if our spawned process is still alive.
            return process?.isRunning == true
        } catch {
            return false
        }
    }
}
