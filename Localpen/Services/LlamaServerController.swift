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

    /// Port for the auxiliary embedding server (EmbeddingGemma), separate from the
    /// main chat server on `port`.
    let embeddingPort: Int = 11435
    private var embeddingProcess: Process?

    /// EmbeddingGemma GGUF, hand-placed for now (real first-run download is deferred).
    /// Filename matches the ggml-org download exactly — capital M.
    static let embeddingModelPath = AppSupport.root()
        .appendingPathComponent("models/embeddinggemma-300M-Q8_0.gguf")

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
        await reapOrphanedServers(matching: "\(binaryURL.path).*--port \(port)",
                                  ownPID: process?.processIdentifier)

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--ctx-size", "\(contextSize)",
            "--n-gpu-layers", "999",
            "--mlock",
            // Time-to-first-token wins on the now-large context prompts (mail bodies,
            // screen OCR): Flash Attention (off by default), a bigger prompt ubatch so the
            // GPU eats the prompt in fewer passes, and KV prefix reuse so the stable
            // system-prompt prefix isn't re-evaluated on every ask.
            "--flash-attn",
            "--ubatch-size", "1024",
            "--cache-reuse", "256"
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

    /// Spawn a second llama-server in embedding mode (EmbeddingGemma), separate from the
    /// main chat server. Mirrors `start()`'s spawn + health-wait + orphan-reap with
    /// `--embeddings --pooling mean`. Best-effort: if the model file is absent it logs and
    /// returns WITHOUT throwing, so retrieval falls back to BM25-only (callers also treat a
    /// thrown spawn/health error as non-fatal). Safe to call after the main server is ready.
    func startEmbeddingServer(modelPath: String) async throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            log.info("embedding model absent at \(modelPath, privacy: .public); skipping embedding server (BM25-only)")
            return
        }
        guard let binaryURL = Bundle.main.url(forResource: "llama-server", withExtension: nil) else {
            log.error("llama-server binary not in bundle Resources; skipping embedding server")
            return
        }

        // Reap only orphaned EMBEDDING servers — scope by the embedding port so we never
        // kill the chat server, which is spawned from this same bundled binary path.
        await reapOrphanedServers(matching: "\(binaryURL.path).*--port \(embeddingPort)",
                                  ownPID: embeddingProcess?.processIdentifier)

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(embeddingPort)",
            "--embeddings",
            "--pooling", "mean",        // ADR-0023 contract: mean pooling
            "--ubatch-size", "8192",
            "--n-gpu-layers", "999"
        ]

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("llama-embed.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()
        proc.standardOutput = handle
        proc.standardError = handle

        try proc.run()
        embeddingProcess = proc
        log.info("llama-server (embeddings) pid=\(proc.processIdentifier) starting on port \(self.embeddingPort)")

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if !proc.isRunning {
                throw NSError(domain: "Localpen", code: 112,
                              userInfo: [NSLocalizedDescriptionKey: "embedding server exited before becoming healthy"])
            }
            if await isHealthy(port: embeddingPort, process: proc) {
                log.info("embedding server ready on port \(self.embeddingPort)")
                return
            }
        }
        throw NSError(domain: "Localpen", code: 113,
                      userInfo: [NSLocalizedDescriptionKey: "embedding server didn't become healthy in 20s"])
    }

    /// Stop the CHAT server only, leaving the (model-independent) embedding server up.
    /// A chat-model switch / crash-restart must not take hybrid retrieval down with it.
    func stopChat() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    /// Full teardown — chat + embedding. For app termination.
    func stop() {
        stopChat()
        embeddingProcess?.terminate()
        embeddingProcess = nil
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
    private func reapOrphanedServers(matching pattern: String, ownPID: pid_t?) async {
        // pgrep is a synchronous subprocess; run it off the main actor so launch /
        // error-retry restart don't hitch the UI. (start() runs on @MainActor.)
        func orphans() async -> [pid_t] {
            await Task.detached { Self.pgrepPIDs(matching: pattern) }.value
                .filter { $0 != ownPID }
        }

        let initial = await orphans()
        guard !initial.isEmpty else { return }
        log.info("reaping \(initial.count) orphaned llama-server(s) from a prior run")
        for pid in initial { kill(pid, SIGTERM) }

        // Wait for them to exit (and release the port) before returning.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await orphans().isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Still alive after SIGTERM — escalate so our bind doesn't fail.
        for pid in await orphans() {
            log.error("orphaned llama-server pid=\(pid) ignored SIGTERM; sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    /// PIDs whose full command line matches `pattern`, via `/usr/bin/pgrep -f`.
    /// Returns [] on any failure — reaping is best-effort. `nonisolated static` so
    /// it can run off the main actor (it touches no instance state).
    private nonisolated static func pgrepPIDs(matching pattern: String) -> [pid_t] {
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
        await isHealthy(port: port, process: process)
    }

    /// Health-check a given port, trusting the 200 only if `proc` (the server we spawned
    /// for it) is still alive — so a foreign service squatting the port is never accepted.
    private func isHealthy(port: Int, process proc: Process?) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return proc?.isRunning == true
        } catch {
            return false
        }
    }
}
