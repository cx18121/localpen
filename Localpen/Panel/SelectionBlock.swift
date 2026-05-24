import SwiftUI

struct SelectionBlock: View {
    let selection: Selection

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s4) {
            Rectangle()
                .fill(Tokens.accentMute)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(selection.text)
                    .italic()
                    .font(Typography.selection)
                    .foregroundStyle(Tokens.textSoft)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text("from \(selection.sourceAppName ?? "another app")")
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(Spacing.s7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
