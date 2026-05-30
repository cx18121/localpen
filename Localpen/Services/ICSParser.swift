import Foundation

/// A parsed VEVENT, before recurrence expansion. Pure value type so the parser +
/// expander are fully unit-testable without any network (ADR 0013).
struct ICSEvent: Equatable {
    let summary: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let rrule: RRule?
    let exdates: [Date]
}

/// The subset of RFC 5545 RRULE that real calendars use. Enough to expand the
/// recurring events Google's `basic.ics` emits (standups, weekly meetings).
/// RECURRENCE-ID instance overrides are NOT modeled — a moved instance shows at
/// its original slot (documented limitation in ADR 0013).
struct RRule: Equatable {
    enum Freq: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    var freq: Freq
    var interval: Int = 1
    var count: Int? = nil
    var until: Date? = nil
    /// Weekday numbers 1=Sun…7=Sat (matching Calendar.component(.weekday)). For WEEKLY.
    var byWeekdays: [Int] = []
    var byMonthDays: [Int] = []
}

enum ICSParser {

    // MARK: - Public API

    /// Parse an iCalendar document into its VEVENTs. Tolerant of CRLF/LF, folded
    /// lines, and unknown properties.
    static func parse(_ text: String, calendar: Calendar = .current) -> [ICSEvent] {
        let lines = unfold(text)
        var events: [ICSEvent] = []

        var inEvent = false
        var summary: String?
        var location: String?
        var start: Date?
        var end: Date?
        var isAllDay = false
        var rrule: RRule?
        var exdates: [Date] = []

        func reset() {
            summary = nil; location = nil; start = nil; end = nil
            isAllDay = false; rrule = nil; exdates = []
        }

        for line in lines {
            if line == "BEGIN:VEVENT" { inEvent = true; reset(); continue }
            if line == "END:VEVENT" {
                if let s = start {
                    // No DTEND → zero-length (point) event ending at start.
                    events.append(ICSEvent(summary: summary ?? "", start: s, end: end ?? s,
                                           isAllDay: isAllDay, location: location,
                                           rrule: rrule, exdates: exdates))
                }
                inEvent = false; reset(); continue
            }
            guard inEvent else { continue }

            let (name, params, value) = splitProperty(line)
            switch name {
            case "SUMMARY":  summary = unescapeText(value)
            case "LOCATION": location = unescapeText(value)
            case "DTSTART":
                if let parsed = parseDate(value, params: params, calendar: calendar) {
                    start = parsed.date; isAllDay = parsed.isAllDay
                }
            case "DTEND":
                if let parsed = parseDate(value, params: params, calendar: calendar) {
                    end = parsed.date
                }
            case "RRULE":
                rrule = parseRRule(value, calendar: calendar)
            case "EXDATE":
                // EXDATE may carry a comma-separated list of date-times.
                for v in value.split(separator: ",") {
                    if let p = parseDate(String(v), params: params, calendar: calendar) {
                        exdates.append(p.date)
                    }
                }
            default: break
            }
        }
        return events
    }

    /// Expand events into concrete occurrences whose START falls in [from, to),
    /// minus EXDATEs. Non-recurring events are included when they intersect the
    /// window. Deterministic given `now`-derived bounds + `calendar`.
    static func expand(_ events: [ICSEvent], from: Date, to: Date,
                       calendar: Calendar = .current) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for e in events {
            let duration = max(0, e.end.timeIntervalSince(e.start))
            guard let rule = e.rrule else {
                // One-off: include if it overlaps the window at all.
                if e.end > from && e.start < to {
                    out.append(makeEvent(e, start: e.start, duration: duration))
                }
                continue
            }
            for occ in occurrences(of: e, rule: rule, from: from, to: to, calendar: calendar) {
                if isExcluded(occ, exdates: e.exdates, calendar: calendar) { continue }
                out.append(makeEvent(e, start: occ, duration: duration))
            }
        }
        return out
    }

    // MARK: - Recurrence expansion

    /// Iteration safety net so a malformed/very-old DAILY rule can't loop forever.
    private static let maxIterations = 2000

    private static func occurrences(of e: ICSEvent, rule: RRule, from: Date, to: Date,
                                    calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = e.start
        var produced = 0
        var iterations = 0

        // For WEEKLY with BYDAY, each "period" is a week; we emit the listed
        // weekdays within that week. Otherwise one occurrence per period.
        while iterations < maxIterations {
            iterations += 1

            let periodOccurrences: [Date]
            if rule.freq == .weekly, !rule.byWeekdays.isEmpty {
                periodOccurrences = weekdayOccurrences(weekOf: cursor, anchor: e.start,
                                                       weekdays: rule.byWeekdays, calendar: calendar)
            } else {
                periodOccurrences = [cursor]
            }

            for occ in periodOccurrences {
                // The occurrence set never precedes DTSTART (a BYDAY day earlier in
                // the first week is not a real occurrence).
                if occ < e.start { continue }
                // Honor COUNT/UNTIL against the canonical occurrence stream.
                if let until = rule.until, occ > until { return result }
                if let count = rule.count, produced >= count { return result }
                produced += 1
                if occ >= from && occ < to { result.append(occ) }
            }

            // Stop once we're past the window (no earlier occurrence can reappear).
            if cursor >= to { break }
            guard let next = advance(cursor, by: rule, calendar: calendar) else { break }
            cursor = next
        }
        return result
    }

    /// The concrete weekday slots in the calendar-week containing `ref`, keeping
    /// the time-of-day from `anchor` (the DTSTART).
    private static func weekdayOccurrences(weekOf ref: Date, anchor: Date,
                                           weekdays: [Int], calendar: Calendar) -> [Date] {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: ref) else { return [] }
        let comps = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        var days: [Date] = []
        var day = weekInterval.start
        while day < weekInterval.end {
            if weekdays.contains(calendar.component(.weekday, from: day)) {
                if let withTime = calendar.date(bySettingHour: comps.hour ?? 0,
                                                minute: comps.minute ?? 0,
                                                second: comps.second ?? 0, of: day) {
                    days.append(withTime)
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }
        return days.sorted()
    }

    private static func advance(_ date: Date, by rule: RRule, calendar: Calendar) -> Date? {
        var comp = DateComponents()
        switch rule.freq {
        case .daily:   comp.day = rule.interval
        case .weekly:  comp.day = 7 * rule.interval
        case .monthly: comp.month = rule.interval
        case .yearly:  comp.year = rule.interval
        }
        return calendar.date(byAdding: comp, to: date)
    }

    private static func isExcluded(_ occ: Date, exdates: [Date], calendar: Calendar) -> Bool {
        // Match on the same minute to tolerate any sub-minute drift between the
        // exdate's stored zone and the expanded occurrence.
        exdates.contains { abs($0.timeIntervalSince(occ)) < 60 }
    }

    private static func makeEvent(_ e: ICSEvent, start: Date, duration: TimeInterval) -> CalendarEvent {
        CalendarEvent(title: e.summary, start: start,
                      end: start.addingTimeInterval(duration),
                      isAllDay: e.isAllDay, location: e.location)
    }

    // MARK: - Property + value parsing

    /// Unfold (RFC 5545 §3.1: a CRLF followed by space/tab continues the prior
    /// line) and split into logical lines.
    private static func unfold(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// Splits "NAME;PARAM=x;PARAM2=y:VALUE" into (NAME, [PARAM:val], VALUE).
    private static func splitProperty(_ line: String) -> (name: String, params: [String: String], value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, [:], "") }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        let parts = head.split(separator: ";").map(String.init)
        let name = parts.first ?? head
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
        }
        return (name.uppercased(), params, value)
    }

    private static func unescapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Parses an iCal DATE or DATE-TIME value into an absolute Date, resolving the
    /// timezone from TZID / a trailing Z (UTC) / floating-local.
    private static func parseDate(_ value: String, params: [String: String],
                                  calendar: Calendar) -> (date: Date, isAllDay: Bool)? {
        let isDateOnly = params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        var cal = calendar

        if isDateOnly {
            // YYYYMMDD — all-day, anchored to start of day in the calendar's zone.
            guard value.count >= 8,
                  let y = Int(value.prefix(4)),
                  let mo = Int(value.dropFirst(4).prefix(2)),
                  let d = Int(value.dropFirst(6).prefix(2)) else { return nil }
            let comps = DateComponents(year: y, month: mo, day: d)
            guard let date = cal.date(from: comps) else { return nil }
            return (cal.startOfDay(for: date), true)
        }

        // DATE-TIME: YYYYMMDDTHHMMSS, optional trailing Z (UTC).
        let utc = value.hasSuffix("Z")
        let v = utc ? String(value.dropLast()) : value
        guard v.count >= 15, v.contains("T") else { return nil }
        let datePart = v.prefix(8)
        let timePart = v.dropFirst(9).prefix(6)   // skip the 'T'
        guard datePart.count == 8, timePart.count == 6,
              let y = Int(datePart.prefix(4)),
              let mo = Int(datePart.dropFirst(4).prefix(2)),
              let d = Int(datePart.dropFirst(6).prefix(2)),
              let h = Int(timePart.prefix(2)),
              let mi = Int(timePart.dropFirst(2).prefix(2)),
              let s = Int(timePart.dropFirst(4).prefix(2)) else { return nil }

        if utc {
            cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        } else if let tzid = params["TZID"], let tz = TimeZone(identifier: tzid) {
            cal.timeZone = tz
        } // else: floating — interpret in the calendar's own zone.

        let comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        guard let date = cal.date(from: comps) else { return nil }
        return (date, false)
    }

    private static func parseRRule(_ value: String, calendar: Calendar) -> RRule? {
        var parts: [String: String] = [:]
        for token in value.split(separator: ";") {
            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { parts[kv[0].uppercased()] = kv[1] }
        }
        guard let freqRaw = parts["FREQ"], let freq = RRule.Freq(rawValue: freqRaw.uppercased()) else {
            return nil
        }
        var rule = RRule(freq: freq)
        if let i = parts["INTERVAL"], let n = Int(i), n > 0 { rule.interval = n }
        if let c = parts["COUNT"], let n = Int(c) { rule.count = n }
        if let u = parts["UNTIL"] {
            rule.until = parseDate(u, params: [:], calendar: calendar)?.date
        }
        if let byday = parts["BYDAY"] {
            rule.byWeekdays = byday.split(separator: ",").compactMap { weekdayNumber(String($0)) }
        }
        if let bymd = parts["BYMONTHDAY"] {
            rule.byMonthDays = bymd.split(separator: ",").compactMap { Int($0) }
        }
        return rule
    }

    /// "MO"/"2TH"/"-1FR" → Calendar weekday number (1=Sun…7=Sat). The leading
    /// ordinal (rarely present in WEEKLY rules) is ignored for our window-bounded
    /// expansion.
    private static func weekdayNumber(_ token: String) -> Int? {
        let day = String(token.suffix(2)).uppercased()
        switch day {
        case "SU": return 1
        case "MO": return 2
        case "TU": return 3
        case "WE": return 4
        case "TH": return 5
        case "FR": return 6
        case "SA": return 7
        default: return nil
        }
    }
}
