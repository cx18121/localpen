import SwiftUI

struct PanelFooter: View {
    let onHistory: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s5) {
            KbdHint("↑↓", "select")
            KbdHint("↩", "apply")
            KbdHint("tab", "edit")
            KbdHint("esc", "close")
            Spacer(minLength: 0)
            Button(action: onHistory) {
                Image(systemName: "clock")
                    .font(Typography.chromeIcon)
                    .foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
            .help("Recent conversations")
        }
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chromeTint)
    }
}
