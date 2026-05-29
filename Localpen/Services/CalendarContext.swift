import Foundation
import EventKit

/// A calendar event reduced to exactly the fields Localpen injects as context.
/// Pure value type with no EventKit dependency so the formatter is unit-testable
/// without a real `EKEventStore` (ADR 0012). `SystemCalendarReader` maps `EKEvent`
/// into this; everything downstream sees only this shape.
struct CalendarEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
}

/// Formats upcoming events into the single `calendar:` context line (ADR 0012):
/// rolling window, grouped by day, titles + times + locations, capped with a
/// `(+N more)` suffix. Pure and deterministic given `now` + `calendar`, so the
/// EventKit boundary never enters a test.
enum CalendarFormatter {
    /// Cap on events rendered into the prompt. The 7-day window can surface many
    /// events; past this the line is noise on a 7B local model, so the rest fold
    /// into a `(+N more)` count rather than flooding the prompt.
    static let maxEvents = 8

    /// Returns the one-line calendar context, or nil when there is nothing to
    /// show. Nil (not "") is the contract: `askUserMessage` emits no `calendar:`
    /// line for nil, keeping an empty calendar byte-identical to no calendar.
    static func format(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> String? {
        guard !events.isEmpty else { return nil }
        let sorted = events.sorted { $0.start < $1.start }
        let shown = Array(sorted.prefix(maxEvents))
        let overflow = sorted.count - shown.count

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = calendar.timeZone
        timeFmt.dateFormat = "h:mm a"

        // Group consecutive events by their calendar day, preserving sort order.
        let today = calendar.startOfDay(for: now)
        var groups: [(label: String, events: [String])] = []
        var currentDayKey: Date?
        for event in shown {
            let dayKey = calendar.startOfDay(for: event.start)
            if dayKey != currentDayKey {
                currentDayKey = dayKey
                groups.append((label: dayLabel(for: dayKey, today: today, calendar: calendar), events: []))
            }
            groups[groups.count - 1].events.append(eventString(event, timeFmt: timeFmt))
        }

        var line = groups
            .map { "\($0.label): \($0.events.joined(separator: ", "))" }
            .joined(separator: "; ")
        if overflow > 0 { line += " (+\(overflow) more)" }
        return line
    }

    /// "Today" / "Tomorrow" / short weekday — relative to the injected `now`'s
    /// day (NOT the system clock), so tests are deterministic. The 7-day window
    /// never repeats a weekday, so a bare "Thu" is unambiguous.
    private static func dayLabel(for dayKey: Date, today: Date, calendar: Calendar) -> String {
        let diff = calendar.dateComponents([.day], from: today, to: dayKey).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let wf = DateFormatter()
            wf.locale = Locale(identifier: "en_US_POSIX")
            wf.timeZone = calendar.timeZone
            wf.dateFormat = "EEE"
            return wf.string(from: dayKey)
        }
    }

    private static func eventString(_ e: CalendarEvent, timeFmt: DateFormatter) -> String {
        // Collapse ALL internal whitespace (incl. newlines) to single spaces:
        // event titles/locations are free text and a embedded newline would split
        // the single `calendar:` line into extra unprefixed <context> lines,
        // breaking the prompt-shape invariant (Codex review MED).
        let collapsedTitle = collapseWhitespace(e.title)
        let title = collapsedTitle.isEmpty ? "(untitled)" : collapsedTitle
        let timePart = e.isAllDay
            ? "(all day)"
            : "\(timeFmt.string(from: e.start))–\(timeFmt.string(from: e.end))"
        var s = "\(title) \(timePart)"
        let loc = collapseWhitespace(e.location ?? "")
        if !loc.isEmpty { s += " @ \(loc)" }
        return s
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Production `CalendarReading`: fetches events in a rolling 7-day window through
/// a fresh `EKEventStore` and formats them. READ-ONLY by construction — only
/// `predicateForEvents` + `events(matching:)` are ever called; there is no path
/// to `save`/`remove` (ADR 0012). `Sendable` so it can run in the probe's
/// off-main detached step; it holds no mutable state and builds its store per call.
struct SystemCalendarReader: ContextProbe.CalendarReading {
    /// Rolling window length. 7 days per ADR 0012's user-chosen scope.
    static let windowDays = 7

    func upcomingContext() -> String? {
        let now = Date()
        let store = EKEventStore()
        guard let end = Calendar.current.date(byAdding: .day, value: Self.windowDays, to: now) else {
            return nil
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).map {
            CalendarEvent(title: $0.title ?? "",
                          start: $0.startDate,
                          end: $0.endDate,
                          isAllDay: $0.isAllDay,
                          location: $0.location)
        }
        return CalendarFormatter.format(events, now: now)
    }
}
