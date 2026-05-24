import SwiftUI
import AppKit

@main
struct LocalpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            if let registry = appDelegate.registry {
                SettingsView(persistence: appDelegate.persistence)
                    .environment(registry)
            } else {
                Text("Loading…")
                    .padding()
            }
        }

        MenuBarExtra("Localpen", systemImage: "pencil.tip") {
            StatusMenu(onOpenPanel: { appDelegate.openPanel() })
        }
    }
}
