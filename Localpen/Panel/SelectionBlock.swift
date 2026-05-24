import SwiftUI

struct SelectionBlock: View {
    let selection: Selection

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s4) {
            Rectangle()
                .fill(Tokens.accentMute)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                // Scrollable region per DESIGN.md §3.4 — max ~4 lines visible,
                // overflow scrolls inside the fixed-height frame.
                ScrollView(.vertical, showsIndicators: false) {
                    Text(selection.text)
                        .italic()
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.textSoft)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: 80, alignment: .topLeading)

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
