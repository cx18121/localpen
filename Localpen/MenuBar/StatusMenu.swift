import SwiftUI

// MenuBarExtra contents per SWIFTUI-SPEC.md §2.1. Real content lands in M4.
// LocalpenApp currently inlines a minimal MenuBarExtra; this is the future home.
struct StatusMenu: View {
    var body: some View {
        Button("Quit Localpen") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
