import SwiftUI

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
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
