import SwiftUI

struct SelectionBlock: View {
    let selection: Selection

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Tokens.accentMute)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(selection.text)
                    .italic()
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textSoft)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text("from \(selection.sourceAppName ?? "another app")")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
