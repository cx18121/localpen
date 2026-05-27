import SwiftUI

struct ThreadListView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent conversations")
                .font(Typography.footerHint)
                .foregroundStyle(Tokens.textMute)
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s4)
            Hairline()
            if controller.recentThreads.isEmpty {
                Text("No conversations yet.")
                    .font(Typography.menuRow)
                    .foregroundStyle(Tokens.textFaint)
                    .padding(Spacing.s7)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(controller.recentThreads, id: \.id) { t in
                            Button { controller.resumeThread(t.id) } label: {
                                HStack {
                                    Text(t.title).font(Typography.menuRow)
                                        .foregroundStyle(Tokens.text).lineLimit(1)
                                    Spacer()
                                    Text(Self.relative(t.updatedAt))
                                        .font(Typography.subhead).foregroundStyle(Tokens.textFaint)
                                }
                                .padding(.horizontal, Spacing.s7).padding(.vertical, Spacing.s4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private static func relative(_ epochMillis: Int64) -> String {
        // ThreadSummary.updatedAt is epoch MILLISECONDS (ConversationStore clock).
        let f = RelativeDateTimeFormatter()
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        return f.localizedString(for: date, relativeTo: Date())
    }
}
