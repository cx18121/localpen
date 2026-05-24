import Foundation
import os

// URLSessionDownloadTask wrapper that exposes progress + atomic move.
// NOT @MainActor — URLSession delegate callbacks arrive on the session's
// delegate queue. State accessed from both API surface and delegate methods
// is serialized via NSLock. The progress closure is hopped to @MainActor.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Equatable, Sendable {
        let bytesDone: Int64
        let bytesTotal: Int64
        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1, Double(bytesDone) / Double(bytesTotal))
        }
    }

    private let lock = NSLock()
    private var destination: URL?
    private var partialURL: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var progressHandler: (@MainActor (Progress) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ModelDownloader")

    func download(from url: URL, to destination: URL, progress: @escaping @MainActor (Progress) -> Void) async throws {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        lock.lock()
        self.destination = destination
        self.partialURL = partial
        self.progressHandler = progress
        lock.unlock()

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        lock.lock()
        self.session = session
        lock.unlock()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = cont
            lock.unlock()
            let task = session.downloadTask(with: url)
            lock.lock()
            self.task = task
            lock.unlock()
            task.resume()
        }

        // didFinishDownloadingTo moved temp → partial. Now atomically rename partial → destination.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        log.info("download complete: \(destination.lastPathComponent, privacy: .public)")

        lock.lock()
        let s = self.session
        self.session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate (nonisolated)

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        guard let handler else { return }
        let p = Progress(bytesDone: totalBytesWritten, bytesTotal: totalBytesExpectedToWrite)
        Task { @MainActor in handler(p) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move SYNCHRONOUSLY here — `location` is invalid after we return.
        lock.lock()
        let partial = partialURL
        lock.unlock()
        guard let partial else { return }
        do {
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }
}
