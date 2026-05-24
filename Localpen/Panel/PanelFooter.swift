import SwiftUI

struct PanelFooter: View {
    var body: some View {
        HStack(spacing: Spacing.s6) {
            hint("↑↓ select")
            hint("↩ apply")
            hint("esc dismiss")
        }
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.panelBG2)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typography.footerHint)
            .foregroundStyle(Tokens.textMute)
    }
}
