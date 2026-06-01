import Foundation

/// Calendar-context configuration (ADR 0013): the user's opt-in toggle plus their
/// secret iCal feed URL(s). There is NO system (EventKit/TCC) permission — macOS
/// won't grant Calendar to this locally-built, non-notarized app, so Localpen
/// reads the user's own read-only iCal feed directly over HTTPS. This relaxes the
/// local-only principle for the calendar source (the fetch goes to the user's
/// calendar provider); see ADR 0013. `isActive` is the hot-path gate the probe
/// consults via `ContextProbe.isCalendarAuthorized`.
enum CalendarAccess {
    private static let enabledKey = "calendarContextEnabled"
    private static let urlsKey = "calendarICSURLs"

    /// The user's Settings toggle. Default false — off until configured.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Raw text the user pasted into Settings — one secret iCal feed URL per line.
    static var icsURLsText: String {
        get { UserDefaults.standard.string(forKey: urlsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlsKey) }
    }

    /// Parsed, valid feed URLs. `webcal://` is normalized to `https://` (Google
    /// hands out either). HTTPS-only: the feed URL is a read credential, so we
    /// never fetch it over plaintext http (Codex review HIGH).
    static var icsURLs: [URL] {
        icsURLsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { raw -> URL? in
                let normalized = raw.hasPrefix("webcal://")
                    ? "https://" + raw.dropFirst("webcal://".count)
                    : raw
                return URL(string: normalized)
            }
            .filter { $0.scheme?.lowercased() == "https" }
    }

    /// Hot-path gate: read calendar context only when enabled AND at least one
    /// feed URL is configured. Cheap + synchronous (no network).
    static var isActive: Bool { isEnabled && !icsURLs.isEmpty }

    /// Kick a background cache refresh (called on launch and when the config
    /// changes) so the chip is warm before the next ask. Gated on `isActive`
    /// (enabled AND has a URL): with the toggle OFF we must NOT fetch the feed,
    /// even if a URL is still saved (Codex review HIGH — opt-in/privacy gate).
    static func refreshNow() {
        guard isActive else { return }
        Task { await ICSCalendarCache.shared.refresh(urls: icsURLs) }
    }
}
