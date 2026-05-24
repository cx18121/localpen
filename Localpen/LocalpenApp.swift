import SwiftUI
import AppKit

@main
struct LocalpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        MenuBarExtra("Localpen", systemImage: "pencil.tip") {
            Button("Quit Localpen") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
