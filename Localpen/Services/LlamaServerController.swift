import Foundation
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
