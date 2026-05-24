import SwiftUI
import AppKit

struct StatusMenu: View {
    let onOpenPanel: () -> Void

    var body: some View {
        Button("Open Panel") { onOpenPanel() }
            .keyboardShortcut(",", modifiers: [.command, .shift])

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("About Localpen") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Divider()

        Button("Quit Localpen") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
