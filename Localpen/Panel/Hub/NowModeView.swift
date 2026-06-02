import SwiftUI

/// Now mode: renders `now.md` — the live "this week" entry point. Read-only here: editing
/// happens in Obsidian (this is a glance surface), reachable via the "Open in editor" door.
/// The brain reads the file; the panel re-reads it on reopen.
struct NowModeView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            if controller.hub.nowText.isEmpty {
                EmptyStateView(
                    icon: "doc.text",
                    title: "now.md is empty",
                    caption: "Your live ‘this week’ page. Edit it in Obsidian; it shows here."
                )
            } else {
                ScrollView {
                    MarkdownText(controller.hub.nowText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.s7)
                }
                .frame(maxHeight: controller.readingMaxHeight)
            }
            HStack {
                Spacer()
                OutlineButton(title: "Open in editor") { controller.hub.openNow() }
            }
            .padding(.horizontal, Spacing.s5)
            .padding(.bottom, Spacing.s4)
        }
    }
}
