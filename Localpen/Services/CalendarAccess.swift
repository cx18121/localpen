import EventKit
import Foundation
import os

/// Calendar-context permission + enable gate (ADR 0012). Two independent facts
/// combine into `isActive`, the single synchronous gate the hotkey hot path
/// consults via `ContextProbe`:
///
/// 1. `isEnabled` — the user's Settings toggle (off by default), backed by
///    UserDefaults. Flipping it off stops calendar injection immediately, even
///    if the system grant is still in place.
/// 2. the EventKit authorization status — must be `.fullAccess` (macOS 14 ships
///    no read-only grant; full access is required just to *read* events).
///
/// Read-only is an app-layer guarantee: nothing here (or in `SystemCalendarReader`)
/// ever calls a write API.
enum CalendarAccess {
    private static let log = Logger(subsystem: "app.localpen.Localpen", category: "CalendarAccess")
    private static let enabledKey = "calendarContextEnabled"

    /// The user's Settings toggle. Default false — the feature does nothing until
    /// turned on once (which is also where the system prompt is triggered).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// OS grant is in place (read via full access — macOS 14 has no read-only).
    static var isAuthorized: Bool { authorizationStatus == .fullAccess }

    /// The user must fix this in System Settings; macOS won't let us re-prompt.
    static var isDeniedOrRestricted: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// The hot-path gate: calendar context is read ONLY when the user enabled it
    /// AND the OS granted access. Cheap + synchronous (no store I/O).
    static var isActive: Bool {
        isEnabled && isAuthorized
    }

    /// Lazily request read access (macOS 14 has no read-only grant, so this asks
    /// for full access — we only ever read). Triggered once from the Settings
    /// toggle, never on launch or in the ask path. The completion fires on an
    /// arbitrary queue, so callers must hop to the main actor before touching UI.
    static func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        EKEventStore().requestFullAccessToEvents { granted, error in
            if let error { log.error("calendar access request failed: \(error.localizedDescription)") }
            completion(granted)
        }
    }
}
