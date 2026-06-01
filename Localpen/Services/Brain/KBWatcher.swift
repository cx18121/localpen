import Foundation
import CoreServices
import os

/// Watches the vault and drives incremental reindex on change (ADR 0014). FSEvents +
/// a 0.75s debounce; filters excluded dirs + non-`.md`. Best-effort: the index is a
/// cache, so a missed event self-heals on the next `reindexAll` (e.g. app launch).
/// `@unchecked Sendable` — all mutable state is confined to `queue` (mirrors the
/// codebase's `ICSCalendarCache` posture).
final class KBWatcher: @unchecked Sendable {
    private let index: BrainIndex
    private let config: BrainConfig
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "KBWatcher")
    private let queue = DispatchQueue(label: "app.localpen.kbwatcher")
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var flush: DispatchWorkItem?

    init(index: BrainIndex, config: BrainConfig = .default) {
        self.index = index
        self.config = config
    }

    func start() { queue.async { [weak self] in self?.startOnQueue() } }

    func stop() {
        queue.async { [weak self] in
            guard let self, let s = self.stream else { return }
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            self.stream = nil
        }
    }

    private func startOnQueue() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &ctx,
                                          [config.vaultRoot.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.5, flags) else {
            log.error("FSEventStreamCreate failed for \(self.config.vaultRoot.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info, let array = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
        Unmanaged<KBWatcher>.fromOpaque(info).takeUnretainedValue().handle(paths: array)
    }

    /// Runs on `queue` (FSEvents dispatches there).
    private func handle(paths: [String]) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            guard url.pathExtension.lowercased() == "md",
                  !url.pathComponents.contains(where: { config.excludedDirComponents.contains($0) }) else { continue }
            pending.insert(p)
        }
        guard !pending.isEmpty else { return }
        flush?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPending() }
        flush = item
        queue.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    private func flushPending() {
        let batch = pending
        pending.removeAll()
        let index = self.index
        Task { for p in batch { await index.reindex(path: URL(fileURLWithPath: p)) } }
    }
}
