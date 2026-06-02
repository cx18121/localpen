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
            OutlineButton(title: error.actionLabel, action: onAction)
        }
        .padding(Spacing.s7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chromeTint)
    }
}
