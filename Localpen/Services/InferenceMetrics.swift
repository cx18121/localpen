// Localpen/Services/InferenceMetrics.swift
import Foundation
import os

/// Which real workload produced a measurement. Keep the raw values stable —
/// they are the `workload` column in the JSONL and any later analysis groups on them.
enum Workload: String {
    case rewrite   // transform / quick-actions (Proofread, Polish, …)
    case ask       // free-form ask over the brain
}

/// Per-request inference telemetry sink. Best-effort and non-fatal: a failed file
/// write must never disturb a user-facing generation. Two outputs:
///   1. os.Logger (category "Metrics") — live tailing via Console.app / `log stream`.
///   2. ~/Library/Logs/Localpen/inference-metrics.jsonl — durable, one JSON row per request.
final class InferenceMetrics: @unchecked Sendable {
    static let shared = InferenceMetrics()

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Metrics")
    private let queue = DispatchQueue(label: "app.localpen.metrics")   // serialize appends
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Localpen", isDirectory: true)
        self.fileURL = fileURL ?? logDir.appendingPathComponent("inference-metrics.jsonl")
    }

    /// Deterministic single-line JSON row. Pure — unit-tested. `acceptance_rate`
    /// is omitted entirely when no draft model is active.
    static func encodeRow(workload: Workload, timings t: ServerTimings, atMillis: Int64) -> String {
        var obj: [String: Any] = [
            "ts_ms": atMillis,
            "workload": workload.rawValue,
            "prompt_n": t.promptN,
            "prompt_ms": t.promptMs,
            "predicted_n": t.predictedN,
            "predicted_ms": t.predictedMs,
            "tok_per_s": t.predictedPerSecond,
        ]
        if let rate = t.acceptanceRate { obj["acceptance_rate"] = rate }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Record one request's timings. Safe to call from any thread / actor.
    func record(_ workload: Workload, _ timings: ServerTimings) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let row = Self.encodeRow(workload: workload, timings: timings, atMillis: ms)
        if let rate = timings.acceptanceRate {
            log.info("\(workload.rawValue, privacy: .public): \(timings.predictedPerSecond, format: .fixed(precision: 1)) tok/s, TTFT \(timings.promptMs, format: .fixed(precision: 0))ms, accept \(rate, format: .fixed(precision: 2))")
        } else {
            log.info("\(workload.rawValue, privacy: .public): \(timings.predictedPerSecond, format: .fixed(precision: 1)) tok/s, TTFT \(timings.promptMs, format: .fixed(precision: 0))ms")
        }
        queue.async { [fileURL, row] in
            guard let line = (row + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)   // first write creates the file
            }
        }
    }
}
