import Foundation
import os

// URLSessionDownloadTask wrapper that exposes progress + atomic move per
// SWIFTUI-SPEC.md §M4.6. Save to a `.partial` filename; rename on success.
@MainActor
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct Progress: Equatable {
        let bytesDone: Int64
        let bytesTotal: Int64
        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1, Double(bytesDone) / Double(bytesTotal))
        }
    }

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private var progressHandler: ((Progress) -> Void)?
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private let log = Logger(subsystem: "app.localpen.Localpen", category: "ModelDownloader")

    func download(from url: URL, to destination: URL, progress: @escaping (Progress) -> Void) async throws {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        self.destination = partial
        self.progressHandler = progress
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 60 * 60   // 1h for big GGUFs
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }

        // On success: atomic rename .partial → final
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        log.info("download complete: \(destination.lastPathComponent, privacy: .public)")

        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let progress = Progress(bytesDone: totalBytesWritten, bytesTotal: totalBytesExpectedToWrite)
        Task { @MainActor in self.progressHandler?(progress) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Move from temp to .partial synchronously here — once we return, location is invalid.
        let destURL: URL? = MainActor.assumeIsolated { self.destination }
        guard let dest = destURL else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in self.continuation?.resume(throwing: error); self.continuation = nil }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error {
                self.continuation?.resume(throwing: error)
            } else {
                self.continuation?.resume()
            }
            self.continuation = nil
        }
    }
}
