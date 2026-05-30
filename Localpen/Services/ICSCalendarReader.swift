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
    private var currentURLs: [URL] = []
    private var fetching = false
    private var pending: [URL]?

    func snapshot() -> [ICSEvent] { lock.withLock { events } }

    func isStale(ttlSeconds: TimeInterval, now: Date) -> Bool {
        lock.withLock {
            guard let last = lastFetch else { return true }
            return now.timeIntervalSince(last) > ttlSeconds
        }
    }

    /// GET every configured feed, parse, and replace the cache. READ-ONLY: only
    /// URLSession GETs happen — no write path to any calendar.
    ///
    /// Single-flight, but NOT lossy: if the feed URLs change while a fetch is in
    /// flight, the new set is queued and re-fetched after, and the stale events
    /// are dropped so an ask can't show the previous calendar (Codex review MED).
    func refresh(urls: [URL], calendar: Calendar = .current) async {
        let proceed: Bool = lock.withLock {
            if fetching {
                pending = urls
                if urls != currentURLs { events = []; lastFetch = nil }   // hide stale until the rerun
                return false
            }
            if urls != currentURLs { events = []; lastFetch = nil }       // drop stale on URL change
            fetching = true
            return true
        }
        guard proceed else { return }

        var toFetch = urls
        while true {
            let fetched = await fetchAndParse(toFetch, calendar: calendar)
            let rerun: [URL]? = lock.withLock {
                if let p = pending, p != toFetch {
                    // URLs changed mid-fetch: these results are stale — discard them
                    // (do NOT publish) and go fetch the latest set instead.
                    pending = nil
                    events = []
                    lastFetch = nil
                    return p
                }
                events = fetched
                lastFetch = Date()
                currentURLs = toFetch
                pending = nil
                fetching = false
                return nil
            }
            guard let next = rerun else { break }
            toFetch = next
        }
    }

    private func fetchAndParse(_ urls: [URL], calendar: Calendar) async -> [ICSEvent] {
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
        return merged
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
