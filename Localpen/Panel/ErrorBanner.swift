import SwiftUI

struct ErrorBanner: View {
    let error: PanelError
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s5) {
            Text(error.displayMessage)
                .font(Typography.body)
                .foregroundStyle(Tokens.accentError)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onAction) {
                Text(error.actionLabel)
                    .font(Typography.body)
                    .padding(.horizontal, Spacing.s5)
                    .padding(.vertical, Spacing.s2)
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.s7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
