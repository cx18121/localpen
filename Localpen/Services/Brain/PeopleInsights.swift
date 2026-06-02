import Foundation

/// Relationship intelligence over the vault's `people/` pages (ADR 0015 — the GBrain CRM
/// value). Buckets people into "follow-ups due", "reconnect" (stale by tier), and the full
/// list, reading `follow_up` / `last_contact` / `relationship_tier` from frontmatter.
///
/// Pure + total so the bucketing is unit-testable with a fixed `today` (no clock).
enum PeopleInsights {
    /// Days since `last_contact` past which a person of each tier is "due to reconnect".
    /// Tunable in one place; unknown/missing tier is treated as casual.
    static func staleThresholdDays(tier: String) -> Int {
        switch tier.lowercased() {
        case "close":  return 21
        case "active": return 60
        default:       return 120
        }
    }

    struct Person: Equatable, Identifiable {
        let page: KBPage
        let tier: String
        let followUp: String?
        let daysSinceContact: Int?
        var id: String { page.path }
        var name: String { page.title }
    }

    struct Result: Equatable {
        var followUpsDue: [Person] = []
        var reconnect: [Person] = []
        var all: [Person] = []
        var isEmpty: Bool { all.isEmpty }
    }

    static func analyze(_ pages: [KBPage], today: Date) -> Result {
        let people = pages.filter { $0.type == .person }.map { person(from: $0, today: today) }
        var r = Result()
        r.all = people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        r.followUpsDue = r.all.filter { $0.followUp != nil }
        r.reconnect = r.all
            .filter { p in (p.daysSinceContact ?? -1) >= staleThresholdDays(tier: p.tier) }
            .sorted { ($0.daysSinceContact ?? 0) > ($1.daysSinceContact ?? 0) }
        return r
    }

    static func person(from page: KBPage, today: Date) -> Person {
        let tier = cleaned(page.frontmatter["relationship_tier"]) ?? "casual"
        let followUp = cleaned(page.frontmatter["follow_up"])
        let days = cleaned(page.frontmatter["last_contact"]).flatMap { daysSince($0, today: today) }
        return Person(page: page, tier: tier, followUp: followUp, daysSinceContact: days)
    }

    /// Whole-day count from a `YYYY-MM-DD` string to `today` (nil if unparseable/empty).
    static func daysSince(_ ymd: String, today: Date) -> Int? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        guard let date = f.date(from: ymd) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: today).day
    }

    /// Clean a raw frontmatter scalar: the parser keeps quotes + inline `# comments`, and
    /// the schema's empty fields are `""` — all of which must read as "absent" (nil).
    static func cleaned(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let hash = s.range(of: " #") {                      // strip an inline comment
            s = String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if s.count >= 2,
           (s.first == "\"" && s.last == "\"") || (s.first == "'" && s.last == "'") {
            s = String(s.dropFirst().dropLast())               // strip surrounding quotes
        }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
