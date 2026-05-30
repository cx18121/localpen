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

    // Calendar context (ADR 0013): an opt-in toggle + the user's secret iCal feed
    // URL(s). No system permission — Localpen reads the read-only feed directly,
    // because macOS won't grant EventKit/TCC to this non-notarized app.
    @State private var calendarEnabled = CalendarAccess.isEnabled
    @State private var calendarURLs = CalendarAccess.icsURLsText

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
                if calendarEnabled {
                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        Text("Secret iCal feed URL — one per line for multiple calendars")
                            .font(Typography.subhead)
                            .foregroundStyle(Tokens.textMute)
                        TextEditor(text: $calendarURLs)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 58)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                                    .stroke(Tokens.textFaint.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
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
            if newValue { CalendarAccess.refreshNow() }
        }
        .onChange(of: calendarURLs) { _, newValue in
            CalendarAccess.icsURLsText = newValue
            if calendarEnabled { CalendarAccess.refreshNow() }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            calendarEnabled = CalendarAccess.isEnabled
            calendarURLs = CalendarAccess.icsURLsText
        }
    }

    private var calendarFooter: String {
        if calendarEnabled && CalendarAccess.icsURLs.isEmpty {
            return "Paste your calendar's read-only iCal URL above. In Google Calendar: Settings → your calendar → Integrate calendar → “Secret address in iCal format”. Localpen fetches it directly (read-only); it goes to your calendar provider, not anywhere else."
        }
        if calendarEnabled {
            return "On. Your next 7 days (titles, times, locations) ride along as a removable context chip on each ask. Read-only; refreshed every few minutes. Keep these URLs private — they grant read access to your calendar."
        }
        return "Let the assistant see your upcoming schedule as context on asks. Uses a read-only iCal feed URL (no macOS calendar permission needed)."
    }
}
