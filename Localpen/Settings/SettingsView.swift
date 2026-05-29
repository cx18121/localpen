import SwiftUI

struct SettingsView: View {
    @Environment(ModelRegistry.self) private var registry
    let persistence: Persistence?
    let switchModel: (String) -> Void

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            ModelPickerView(registry: registry, switchModel: switchModel)
                .tabItem { Label("Model", systemImage: "cube") }

            HistorySettingsView(persistence: persistence)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        // One consistent window size; each grouped Form scrolls within it and
        // manages its own section insets, so tabs no longer hand-tune padding/frames.
        .frame(width: 500, height: 400)
    }
}

private struct GeneralTab: View {
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
