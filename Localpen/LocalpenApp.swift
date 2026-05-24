import SwiftUI
import AppKit

@main
struct LocalpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(persistence: appDelegate.persistence)
                .environment(appDelegate.registry)
                .frame(width: 480, height: 320)
        }

        MenuBarExtra("Localpen", systemImage: "pencil.tip") {
            StatusMenu(onOpenPanel: { appDelegate.openPanel() })
        }
    }
}
