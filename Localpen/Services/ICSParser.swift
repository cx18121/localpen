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

/// A BYDAY entry: a weekday with an optional ordinal (e.g. `3TH` = 3rd Thursday,
/// `-1FR` = last Friday). Ordinal is used for MONTHLY/YEARLY; ignored for WEEKLY.
struct ByDay: Equatable {
    let ordinal: Int?
    let weekday: Int   // 1=Sun…7=Sat (Calendar.component(.weekday))
}

/// The subset of RFC 5545 RRULE that real calendars use. Enough to expand the
/// recurring events Google's `basic.ics` emits. RECURRENCE-ID instance overrides
/// (a single moved/edited occurrence) are NOT modeled — such an instance shows at
/// its original slot (documented limitation in ADR 0013).
struct RRule: Equatable {
    enum Freq: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    var freq: Freq
    var interval: Int = 1
    var count: Int? = nil
    var until: Date? = nil
    var byDays: [ByDay] = []
    var byMonthDays: [Int] = []
    var byMonths: [Int] = []
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
        var status: String?

        func reset() {
            summary = nil; location = nil; start = nil; end = nil
            isAllDay = false; rrule = nil; exdates = []; status = nil
        }

        for line in lines {
            if line == "BEGIN:VEVENT" { inEvent = true; reset(); continue }
            if line == "END:VEVENT" {
                // Skip canceled events (STATUS:CANCELLED) — a canceled meeting must
                // not show in the context as if active (Codex review MED).
                if let s = start, status != "CANCELLED" {
                    // RFC 5545: a DATE DTSTART with no DTEND defaults to a 1-day
                    // duration; a DATE-TIME with no DTEND is a zero-length (point)
                    // event. Without the all-day default, a today all-day event
                    // (end == start == midnight) is dropped once `now` passes
                    // midnight (Codex review MED).
                    let resolvedEnd: Date
                    if let e = end {
                        resolvedEnd = e
                    } else if isAllDay {
                        resolvedEnd = calendar.date(byAdding: .day, value: 1, to: s) ?? s
                    } else {
                        resolvedEnd = s
                    }
                    events.append(ICSEvent(summary: summary ?? "", start: s, end: resolvedEnd,
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
            case "STATUS":
                status = value.uppercased()
            case "RRULE":
                rrule = parseRRule(value, calendar: calendar)
            case "EXDATE":
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
    /// window. Deterministic given the bounds + `calendar`.
    static func expand(_ events: [ICSEvent], from: Date, to: Date,
                       calendar: Calendar = .current) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for e in events {
            let duration = max(0, e.end.timeIntervalSince(e.start))
            guard let rule = e.rrule else {
                if e.end > from && e.start < to {
                    out.append(makeEvent(e, start: e.start, duration: duration))
                }
                continue
            }
            for occ in occurrences(of: e, rule: rule, from: from, to: to, calendar: calendar) {
                if isExcluded(occ, exdates: e.exdates) { continue }
                out.append(makeEvent(e, start: occ, duration: duration))
            }
        }
        return out
    }

    // MARK: - Recurrence expansion

    /// Per-window iteration safety net (a malformed rule can't loop forever). The
    /// fast-forward below means we normally start near `from`, so this is just a
    /// backstop.
    private static let maxIterations = 800

    private static func occurrences(of e: ICSEvent, rule: RRule, from: Date, to: Date,
                                    calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var produced = 0
        let duration = max(0, e.end.timeIntervalSince(e.start))
        // One occurrence per period ⇒ skipped-period count == skipped-occurrence
        // count, so fast-forward is exact even with COUNT.
        let singlePerPeriod = rule.byDays.isEmpty && rule.byMonthDays.isEmpty && rule.byMonths.count <= 1

        // Jump the cursor near `from` so an ancient series still reaches the window
        // within the cap (Codex review MED). Safe with COUNT only when single per
        // period — then the skipped occurrences are accounted into `produced`.
        var cursor = e.start
        if rule.count == nil || singlePerPeriod {
            let (jumped, skipped) = fastForward(from: e.start, toward: from, rule: rule, calendar: calendar)
            cursor = jumped
            if rule.count != nil { produced = skipped }
        }

        var iterations = 0
        while iterations < maxIterations {
            iterations += 1

            for occ in periodOccurrences(cursor: cursor, anchor: e.start, rule: rule, calendar: calendar) {
                if occ < e.start { continue }                     // never precede DTSTART
                if let until = rule.until, occ > until { return result }
                if let count = rule.count, produced >= count { return result }
                produced += 1
                // Interval intersection (not just start ≥ from), so an all-day or
                // long occurrence that began before `from` but still covers it is
                // included — e.g. a birthday at midnight is shown all day (Codex MED).
                if occ.addingTimeInterval(duration) > from && occ < to { result.append(occ) }
            }

            if cursor >= to { break }
            guard let next = advance(cursor, by: rule, calendar: calendar) else { break }
            cursor = next
        }
        return result.sorted()
    }

    /// The concrete occurrence start(s) within the period anchored at `cursor`,
    /// dispatched by FREQ + BY-rules. Time-of-day always comes from `anchor`
    /// (DTSTART).
    private static func periodOccurrences(cursor: Date, anchor: Date, rule: RRule,
                                          calendar: Calendar) -> [Date] {
        let time = calendar.dateComponents([.hour, .minute, .second], from: anchor)
        switch rule.freq {
        case .daily:
            return [cursor]
        case .weekly:
            guard !rule.byDays.isEmpty else { return [cursor] }
            return weekdaySlots(inWeekOf: cursor, weekdays: rule.byDays.map(\.weekday),
                                time: time, calendar: calendar)
        case .monthly:
            return monthlyOccurrences(inMonthOf: cursor, rule: rule, time: time, calendar: calendar) ?? [cursor]
        case .yearly:
            // Restrict to BYMONTH (or DTSTART's month), then apply the month
            // BY-rules — covers holiday-style "BYMONTH=11;BYDAY=4TH".
            let year = calendar.component(.year, from: cursor)
            let months = rule.byMonths.isEmpty ? [calendar.component(.month, from: anchor)] : rule.byMonths
            var out: [Date] = []
            var hadByRule = false
            for m in months {
                guard let ref = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { continue }
                if let occ = monthlyOccurrences(inMonthOf: ref, rule: rule, time: time, calendar: calendar) {
                    hadByRule = true
                    out.append(contentsOf: occ)
                }
            }
            if hadByRule { return out.sorted() }
            // No day/monthday BY-rule → DTSTART's day in each target month.
            if rule.byMonths.isEmpty { return [cursor] }
            let day = calendar.component(.day, from: anchor)
            return months.compactMap { m -> Date? in
                guard let ref = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { return nil }
                return monthDaySlot(inMonthOf: ref, day: day, time: time, calendar: calendar)
            }.sorted()
        }
    }

    /// Occurrences within the month containing `ref`, driven by BYMONTHDAY or
    /// ordinal BYDAY. Returns nil when neither is set (caller picks the plain
    /// behavior). Shared by MONTHLY and YEARLY.
    private static func monthlyOccurrences(inMonthOf ref: Date, rule: RRule,
                                           time: DateComponents, calendar: Calendar) -> [Date]? {
        if !rule.byMonthDays.isEmpty {
            return rule.byMonthDays.compactMap {
                monthDaySlot(inMonthOf: ref, day: $0, time: time, calendar: calendar)
            }.sorted()
        }
        if !rule.byDays.isEmpty {
            return rule.byDays.flatMap {
                monthWeekdaySlots(inMonthOf: ref, byDay: $0, time: time, calendar: calendar)
            }.sorted()
        }
        return nil
    }

    /// Jump from `start` to one period before `from`, so iteration reaches the
    /// window quickly. Returns `(start, 0)` when already at/after `from`; the Int
    /// is the number of whole periods skipped (== occurrences skipped when the
    /// rule yields one occurrence per period).
    private static func fastForward(from start: Date, toward target: Date,
                                    rule: RRule, calendar: Calendar) -> (cursor: Date, skipped: Int) {
        guard target > start else { return (start, 0) }
        let unit: Calendar.Component
        let perStepDays: Int?
        switch rule.freq {
        case .daily:   unit = .day;   perStepDays = rule.interval
        case .weekly:  unit = .day;   perStepDays = 7 * rule.interval
        case .monthly: unit = .month; perStepDays = nil
        case .yearly:  unit = .year;  perStepDays = nil
        }
        if let perStepDays, perStepDays > 0 {
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            let steps = max(0, days / perStepDays - 1)
            var comp = DateComponents(); comp.day = steps * perStepDays
            return (calendar.date(byAdding: comp, to: start) ?? start, steps)
        } else {
            let units = calendar.dateComponents([unit], from: start, to: target).value(for: unit) ?? 0
            let steps = max(0, units / rule.interval - 1)
            var comp = DateComponents(); comp.setValue(steps * rule.interval, for: unit)
            return (calendar.date(byAdding: comp, to: start) ?? start, steps)
        }
    }

    private static func weekdaySlots(inWeekOf ref: Date, weekdays: [Int],
                                     time: DateComponents, calendar: Calendar) -> [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: ref) else { return [] }
        return daysMatching({ weekdays.contains(calendar.component(.weekday, from: $0)) },
                            in: week, time: time, calendar: calendar)
    }

    private static func monthDaySlot(inMonthOf ref: Date, day: Int,
                                     time: DateComponents, calendar: Calendar) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: ref) else { return nil }
        let range = calendar.range(of: .day, in: .month, for: ref) ?? 1..<32
        let target = day > 0 ? day : (range.count + day + 1)   // -1 = last day
        guard range.contains(target) else { return nil }
        var comps = calendar.dateComponents([.year, .month], from: month.start)
        comps.day = target
        comps.hour = time.hour; comps.minute = time.minute; comps.second = time.second
        return calendar.date(from: comps)
    }

    private static func monthWeekdaySlots(inMonthOf ref: Date, byDay: ByDay,
                                          time: DateComponents, calendar: Calendar) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: ref) else { return [] }
        let matches = daysMatching({ calendar.component(.weekday, from: $0) == byDay.weekday },
                                   in: month, time: time, calendar: calendar)
        guard let ordinal = byDay.ordinal else { return matches }   // every such weekday
        if ordinal > 0, ordinal <= matches.count { return [matches[ordinal - 1]] }
        if ordinal < 0, -ordinal <= matches.count { return [matches[matches.count + ordinal]] }
        return []
    }

    /// Days within `interval` whose date passes `predicate`, stamped with `time`.
    private static func daysMatching(_ predicate: (Date) -> Bool, in interval: DateInterval,
                                     time: DateComponents, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            if predicate(day),
               let stamped = calendar.date(bySettingHour: time.hour ?? 0,
                                           minute: time.minute ?? 0,
                                           second: time.second ?? 0, of: day) {
                out.append(stamped)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
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

    private static func isExcluded(_ occ: Date, exdates: [Date]) -> Bool {
        exdates.contains { abs($0.timeIntervalSince(occ)) < 60 }
    }

    private static func makeEvent(_ e: ICSEvent, start: Date, duration: TimeInterval) -> CalendarEvent {
        CalendarEvent(title: e.summary, start: start,
                      end: start.addingTimeInterval(duration),
                      isAllDay: e.isAllDay, location: e.location)
    }

    // MARK: - Property + value parsing

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

    private static func parseDate(_ value: String, params: [String: String],
                                  calendar: Calendar) -> (date: Date, isAllDay: Bool)? {
        let isDateOnly = params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))
        var cal = calendar

        if isDateOnly {
            guard value.count >= 8,
                  let y = Int(value.prefix(4)),
                  let mo = Int(value.dropFirst(4).prefix(2)),
                  let d = Int(value.dropFirst(6).prefix(2)) else { return nil }
            guard let date = cal.date(from: DateComponents(year: y, month: mo, day: d)) else { return nil }
            return (cal.startOfDay(for: date), true)
        }

        let utc = value.hasSuffix("Z")
        let v = utc ? String(value.dropLast()) : value
        guard v.count >= 15, v.contains("T") else { return nil }
        let datePart = v.prefix(8)
        let timePart = v.dropFirst(9).prefix(6)
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
        } // else floating — interpret in the calendar's own zone.

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
            rule.byDays = byday.split(separator: ",").compactMap { parseByDay(String($0)) }
        }
        if let bymd = parts["BYMONTHDAY"] {
            rule.byMonthDays = bymd.split(separator: ",").compactMap { Int($0) }
        }
        if let bymo = parts["BYMONTH"] {
            rule.byMonths = bymo.split(separator: ",").compactMap { Int($0) }
        }
        return rule
    }

    /// "MO" / "3TH" / "-1FR" → (ordinal?, weekday).
    private static func parseByDay(_ token: String) -> ByDay? {
        let t = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard t.count >= 2, let weekday = weekdayNumber(String(t.suffix(2))) else { return nil }
        let ordinalPart = String(t.dropLast(2))
        let ordinal = ordinalPart.isEmpty ? nil : Int(ordinalPart)
        return ByDay(ordinal: ordinal, weekday: weekday)
    }

    private static func weekdayNumber(_ day: String) -> Int? {
        switch day.uppercased() {
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
