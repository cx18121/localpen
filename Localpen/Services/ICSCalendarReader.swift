import Foundation
import os

/// Thread-safe, per-feed cache of parsed VEVENTs from the user's ICS feed(s).
/// The network GET is the slow part, so it's cached + refreshed on a TTL;
/// expansion to the next-7-days window happens fresh at read time (relative to
/// `now`). `@unchecked Sendable`: all mutable state is guarded by `lock`.
///
/// Per-feed last-good (Codex review): a transient HTTP failure on one feed must
/// NOT erase that feed's events (we keep the last good parse), and a failure on
/// one feed must not affect another feed's events.
final class ICSCalendarCache: @unchecked Sendable {
    /// Returns parsed events for a feed, or nil on failure (network error / non-2xx).
    typealias Fetcher = @Sendable (URL) async -> [ICSEvent]?

    static let shared = ICSCalendarCache()

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ICSCalendar")
    private let lock = NSLock()
    private let fetch: Fetcher
    private var eventsByURL: [URL: [ICSEvent]] = [:]   // last-good parse per feed
    private var lastSuccess: Date?
    private var currentURLs: [URL] = []
    private var fetching = false
    private var pending: [URL]?

    init(fetch: @escaping Fetcher = ICSCalendarCache.defaultFetch) {
        self.fetch = fetch
    }

    /// Events for exactly the currently-configured feeds (removed feeds drop out
    /// immediately, even mid-refresh, because we filter by `currentURLs`).
    func snapshot() -> [ICSEvent] {
        lock.withLock { currentURLs.flatMap { eventsByURL[$0] ?? [] } }
    }

    /// Stale when no successful fetch yet, or the last success is older than TTL.
    /// Keys on success — a run that failed every feed stays stale so we retry.
    func isStale(ttlSeconds: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            guard let last = lastSuccess else { return true }
            return now.timeIntervalSince(last) > ttlSeconds
        }
    }

    /// GET every configured feed, parse, and update per-feed caches. READ-ONLY:
    /// only GETs happen. Single-flight; a feed-URL change mid-fetch is queued and
    /// re-run, and `snapshot()` filtering by `currentURLs` means stale/removed
    /// feeds never surface during the change.
    func refresh(urls: [URL]) async {
        let proceed: Bool = lock.withLock {
            currentURLs = urls
            if fetching { pending = urls; return false }
            fetching = true
            return true
        }
        guard proceed else { return }

        var toFetch = urls
        while true {
            var anySuccess = false
            for url in toFetch {
                if let parsed = await fetch(url) {
                    lock.withLock { eventsByURL[url] = parsed }
                    anySuccess = true
                }
                // On failure: keep this feed's last-good events (do nothing).
            }
            let next: [URL]? = lock.withLock {
                if anySuccess { lastSuccess = Date() }
                eventsByURL = eventsByURL.filter { currentURLs.contains($0.key) }   // drop removed feeds
                if let p = pending, p != toFetch { pending = nil; return p }
                pending = nil
                fetching = false
                return nil
            }
            guard let n = next else { break }
            toFetch = n
        }
    }

    /// Default production fetcher: HTTPS GET, require a 2xx status, parse with the
    /// current calendar. Returns nil on any error / non-2xx so the cache keeps the
    /// feed's last good events instead of blanking it.
    static let defaultFetch: Fetcher = { url in
        let log = Logger(subsystem: "app.localpen.Localpen", category: "ICSCalendar")
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.error("ICS feed non-2xx: \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                return nil
            }
            return ICSParser.parse(String(decoding: data, as: UTF8.self), calendar: .current)
        } catch {
            log.error("ICS feed fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Production `CalendarReading` backed by the user's ICS feed(s) (ADR 0013).
/// READ-ONLY by construction: it only reads the cache, which is populated by
/// `URLSession` GETs of the user's secret iCal URL(s). `upcomingContext()` is
/// fast — it reads the cache and expands the 7-day window in memory; a stale
/// cache triggers a background refresh for next time rather than blocking.
struct ICSCalendarReader: ContextProbe.CalendarReading {
    static let windowDays = 7
    static let ttlSeconds: TimeInterval = 600   // 10 minutes

    func upcomingContext() -> String? {
        let now = Date()
        let cache = ICSCalendarCache.shared
        let urls = CalendarAccess.icsURLs
        if !urls.isEmpty, cache.isStale(ttlSeconds: Self.ttlSeconds, now: now) {
            Task { await cache.refresh(urls: urls) }   // warm for next time; don't block this read
        }
        guard let end = Calendar.current.date(byAdding: .day, value: Self.windowDays, to: now) else {
            return nil
        }
        let events = ICSParser.expand(cache.snapshot(), from: now, to: end)
        return CalendarFormatter.format(events, now: now)
    }
}
