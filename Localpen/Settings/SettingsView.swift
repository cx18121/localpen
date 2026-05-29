import SwiftUI
import AppKit

/// The General settings pane. The Settings window itself is an AppKit
/// `NSTabViewController(.toolbar)` built in `AppDelegate.openSettings` — that
/// gives the native System-Preferences toolbar tabs + per-pane window sizing,
/// while staying an on-demand AppKit window (the SwiftUI `Settings` scene is
/// avoided: on macOS 14 it auto-opens at launch, and the suppression fix is
/// macOS 15+). Each pane is a grouped `Form`.
struct GeneralSettingsView: View {
    // Mirrors SMAppService status into view state; re-read on appear so an
    // out-of-app change (System Settings > Login Items) reflects when reopened.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    // Calendar context (ADR 0012). `calendarEnabled` is the user's intent;
    // `calendarAuthorized` mirrors the OS grant so the footer can guide the user
    // to System Settings when they enabled it but the grant is missing.
    @State private var calendarEnabled = CalendarAccess.isEnabled
    @State private var calendarAuthorized = CalendarAccess.isAuthorized
    @State private var calendarDenied = CalendarAccess.isDeniedOrRestricted

    var body: some View {
        Form {
            Section {
                HotkeyRecorderView()
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Press the chord you want to use. Conflicts with other apps are flagged.")
            }

            Section {
                Toggle("Use calendar context", isOn: $calendarEnabled)
            } header: {
                Text("Calendar")
            } footer: {
                Text(calendarFooter)
            }

            Section {
                Toggle("Launch Localpen at login", isOn: $launchAtLogin)
            } header: {
                Text("Startup")
            } footer: {
                Text("Open Localpen automatically when you log in.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: launchAtLogin) { _, newValue in
            LaunchAtLogin.isEnabled = newValue
        }
        .onChange(of: calendarEnabled) { _, newValue in
            CalendarAccess.isEnabled = newValue
            // Request the OS grant the first time it's switched on. macOS can only
            // prompt from .notDetermined; if already .denied the user must fix it in
            // System Settings (the footer says so). The completion is on an arbitrary
            // queue — hop to the main actor before touching view state.
            if newValue, !CalendarAccess.isAuthorized, !CalendarAccess.isDeniedOrRestricted {
                CalendarAccess.requestAccess { _ in
                    Task { @MainActor in refreshCalendarStatus() }
                }
            }
            refreshCalendarStatus()
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            refreshCalendarStatus()
        }
        // Returning from System Settings (where the user may have just granted or
        // revoked calendar access) reactivates the app — re-read the live status so
        // the footer guidance can't go stale while this window stays open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCalendarStatus()
        }
    }

    private func refreshCalendarStatus() {
        calendarEnabled = CalendarAccess.isEnabled
        calendarAuthorized = CalendarAccess.isAuthorized
        calendarDenied = CalendarAccess.isDeniedOrRestricted
    }

    private var calendarFooter: String {
        if calendarEnabled && calendarDenied {
            return "Calendar access is turned off in macOS. Open System Settings → Privacy & Security → Calendars and allow Localpen, then toggle this off and on."
        }
        if calendarEnabled && calendarAuthorized {
            return "On. Your next 7 days (titles, times, locations — never edited) ride along as a removable context chip on each ask. Read-only; nothing leaves this Mac."
        }
        return "Let the assistant see your upcoming schedule as context on asks. Read-only — Localpen never edits your calendar, and nothing leaves this Mac."
    }
}
