import SwiftUI
import AppKit

@main
struct LocalpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Only MenuBarExtra — no SwiftUI Settings scene because on macOS 14
        // it auto-materializes its window on launch, and there's no
        // `.defaultLaunchBehavior(.suppressed)` until macOS 15. Settings is
        // a regular AppKit NSWindow created on demand by AppDelegate.
        MenuBarExtra("Localpen", systemImage: "pencil.tip") {
            StatusMenu(
                onOpenPanel: { appDelegate.openPanel() },
                onOpenSettings: { appDelegate.showSettings() }
            )
        }
    }
}
