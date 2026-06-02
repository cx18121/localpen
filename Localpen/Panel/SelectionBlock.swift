import SwiftUI

struct SelectionBlock: View {
    let selection: Selection

    /// ~4 lines of captured text (DESIGN §3.4) before the block scrolls internally.
    private static let maxVisibleHeight: CGFloat = 80

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s4) {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                // Scrollable region per DESIGN.md §3.4 — max ~4 lines visible,
                // overflow scrolls inside the fixed-height frame.
                ScrollView(.vertical, showsIndicators: false) {
                    Text(selection.text)
                        .italic()
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.textSoft)
                        .lineSpacing(Spacing.s1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                // ~4 lines visible (DESIGN §3.4); overflow scrolls inside this cap.
                .frame(maxWidth: .infinity, maxHeight: Self.maxVisibleHeight, alignment: .topLeading)

                Text("from \(selection.sourceAppName ?? "another app")")
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(Spacing.s7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
