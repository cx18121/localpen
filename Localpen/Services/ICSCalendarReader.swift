import Foundation
import os

/// Thread-safe cache of parsed VEVENTs from the user's ICS feed(s). The network
/// GET is the slow part, so it's cached + refreshed on a TTL; expansion to the
/// next-7-days window happens fresh at read time (relative to `now`), so a
/// long-lived cache still produces correct day labels. `@unchecked Sendable`:
/// all mutable state is guarded by `lock`.
final class ICSCalendarCache: @unchecked Sendable {
    static let shared = ICSCalendarCache()

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "ICSCalendar")
    private let lock = NSLock()
    private var events: [ICSEvent] = []
    private var lastFetch: Date?
    private var fetching = false

    func snapshot() -> [ICSEvent] { lock.withLock { events } }

    func isStale(ttlSeconds: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            guard let last = lastFetch else { return true }
            return now.timeIntervalSince(last) > ttlSeconds
        }
    }

    /// GET every configured feed, parse, and replace the cache. Coalesces
    /// concurrent calls so a burst of asks triggers only one fetch. READ-ONLY:
    /// only URLSession GETs happen here — there is no write path to any calendar.
    func refresh(urls: [URL], calendar: Calendar = .current) async {
        let alreadyFetching = lock.withLock { () -> Bool in
            if fetching { return true }
            fetching = true
            return false
        }
        if alreadyFetching { return }
        defer { lock.withLock { fetching = false } }

        var merged: [ICSEvent] = []
        for url in urls {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 12
                req.httpMethod = "GET"
                let (data, _) = try await URLSession.shared.data(for: req)
                merged.append(contentsOf: ICSParser.parse(String(decoding: data, as: UTF8.self),
                                                           calendar: calendar))
            } catch {
                log.error("ICS feed fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.withLock { events = merged; lastFetch = Date() }
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
        // Warm the cache for next time if it's stale; never block this read on it.
        if !urls.isEmpty, cache.isStale(ttlSeconds: Self.ttlSeconds, now: now) {
            Task { await cache.refresh(urls: urls) }
        }
        guard let end = Calendar.current.date(byAdding: .day, value: Self.windowDays, to: now) else {
            return nil
        }
        let events = ICSParser.expand(cache.snapshot(), from: now, to: end)
        return CalendarFormatter.format(events, now: now)
    }
}
