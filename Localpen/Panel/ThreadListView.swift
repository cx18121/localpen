import SwiftUI

struct ThreadListView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Recent")

            ScrollView {
                VStack(spacing: 2) {
                    MenuRow(
                        icon: "person.crop.square",
                        title: "Your writing profile",
                        trailing: .chevron
                    ) { controller.showProfile() }

                    if controller.recentThreads.isEmpty {
                        EmptyStateView(
                            icon: "bubble.left.and.text.bubble.right",
                            title: "No conversations yet",
                            caption: "Ask a question or refine a result to start one."
                        )
                    } else {
                        Hairline().padding(.vertical, Spacing.s3)
                        ForEach(controller.recentThreads, id: \.id) { t in
                            MenuRow(
                                icon: "bubble.left.and.text.bubble.right",
                                title: t.title.isEmpty ? "Untitled" : t.title,
                                trailing: .text(Self.relative(t.updatedAt))
                            ) { controller.resumeThread(t.id) }
                        }
                    }
                }
                .padding(.horizontal, Spacing.s4)
                .padding(.bottom, Spacing.s4)
            }
            .frame(maxHeight: controller.readingMaxHeight)
        }
    }

    private static func relative(_ epochMillis: Int64) -> String {
        // ThreadSummary.updatedAt is epoch MILLISECONDS (ConversationStore clock).
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        return f.localizedString(for: date, relativeTo: Date())
    }
}
