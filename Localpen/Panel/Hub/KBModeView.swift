import SwiftUI

/// Knowledge mode: a search field over the vault index + a result list (recent notes
/// when the query is empty). Selecting a note opens it in Obsidian. Empty / brain-off
/// ⇒ an empty state pointing at the Settings toggle.
struct KBModeView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search notes…", text: $controller.hub.query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s4)
                .onChange(of: controller.hub.query) { _, _ in controller.hub.searchNotes() }
            Hairline()

            if controller.hub.notes.isEmpty {
                EmptyStateView(
                    icon: "book.closed",
                    title: controller.hub.query.isEmpty ? "No notes indexed" : "No matches",
                    caption: controller.hub.query.isEmpty
                        ? "Enable the knowledge base in Settings, then your cxkb notes appear here."
                        : nil
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        SectionHeader(title: controller.hub.query.isEmpty ? "Recent notes" : "Results",
                                      trailing: "\(controller.hub.notes.count)")
                        ForEach(controller.hub.notes, id: \.path) { page in
                            MenuRow(icon: "doc.text", title: page.title,
                                    trailing: page.area.isEmpty ? .chevron : .text(page.area)) {
                                controller.hub.openNote(page)
                            }
                        }
                    }
                }
                .frame(maxHeight: controller.readingMaxHeight)
            }
        }
    }
}
