import SwiftUI
import AppKit

struct StatusMenu: View {
    let onOpenPanel: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Button("Open Panel") { onOpenPanel() }
            .keyboardShortcut(",", modifiers: [.command, .shift])

        Button("Settings…") { onOpenSettings() }
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
