import SwiftUI

struct ThreadListView: View {
    @Bindable var controller: PanelController

    @State private var hoveredID: Int64? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Tokens.textFaint)
                .padding(.horizontal, Spacing.s7)
                .padding(.top, Spacing.s6)
                .padding(.bottom, Spacing.s3)

            if controller.recentThreads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(controller.recentThreads, id: \.id) { t in
                            row(t)
                        }
                    }
                    .padding(.horizontal, Spacing.s4)
                    .padding(.bottom, Spacing.s4)
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func row(_ t: ThreadSummary) -> some View {
        Button { controller.resumeThread(t.id) } label: {
            HStack(spacing: Spacing.s4) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textFaint)
                    .frame(width: 18)
                Text(t.title.isEmpty ? "Untitled" : t.title)
                    .font(Typography.menuRow)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Spacer(minLength: Spacing.s4)
                Text(Self.relative(t.updatedAt))
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.s5)
            .padding(.vertical, Spacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                    .fill(Tokens.rowHighlight)
                    .opacity(hoveredID == t.id ? 0.7 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredID = t.id }
            else if hoveredID == t.id { hoveredID = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s3) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textFaint)
            Text("No conversations yet")
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.textMute)
            Text("Refine a result to start one.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s8 + Spacing.s6)
    }

    private static func relative(_ epochMillis: Int64) -> String {
        // ThreadSummary.updatedAt is epoch MILLISECONDS (ConversationStore clock).
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        return f.localizedString(for: date, relativeTo: Date())
    }
}
