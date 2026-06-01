import SwiftUI

/// Now mode: renders `now.md` — the live "this week" entry point — read-only for v1.
/// Editing happens in Obsidian (this is a glance surface); the brain reads the file.
struct NowModeView: View {
    @Bindable var controller: PanelController

    var body: some View {
        if controller.hubNowText.isEmpty {
            EmptyStateView(
                icon: "doc.text",
                title: "now.md is empty",
                caption: "Your live ‘this week’ page. Edit it in Obsidian — it shows here."
            )
        } else {
            ScrollView {
                Text(controller.hubNowText)
                    .font(Typography.body)
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s7)
            }
            .frame(maxHeight: 320)
        }
    }
}
