import Foundation
import os

// URLSessionDownloadTask wrapper exposing progress + an atomic move into place.
// The public surface (download/cancel) is @MainActor-confined, so its mutable
// state is only ever touched on the main actor. The URLSession delegate
// callbacks are nonisolated but only read state established *before* resume()
// (a happens-before edge URLSession guarantees) or resume the continuation —
// so no lock is needed.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        let bytesDone: Int64
        let bytesTotal: Int64
        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1, Double(bytesDone) / Double(bytesTotal))
        }
    }

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ModelDownloader")
    private var partialURL: URL?
    private var progressHandler: (@MainActor (Progress) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var downloadTask: URLSessionDownloadTask?

    @MainActor
    func download(from url: URL, to destination: URL, progress: @escaping @MainActor (Progress) -> Void) async throws {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        partialURL = partial
        progressHandler = progress

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            let task = session.downloadTask(with: url)
            downloadTask = task
            task.resume()
        }

        // didFinishDownloadingTo moved the temp file → partial. Rename
        // partial → destination (same volume → fast atomic move).
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        log.info("download complete: \(destination.lastPathComponent, privacy: .public)")
    }

    @MainActor
    func cancel() {
        downloadTask?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate (nonisolated)

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let handler = progressHandler else { return }
        let p = Progress(bytesDone: totalBytesWritten, bytesTotal: totalBytesExpectedToWrite)
        Task { @MainActor in handler(p) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move SYNCHRONOUSLY — `location` is invalid after we return.
        guard let partial = partialURL else { return }
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
