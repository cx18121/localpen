import SwiftUI

struct PanelFooter: View {
    var body: some View {
        HStack(spacing: Spacing.s5) {
            KbdHint("↑↓", "select")
            KbdHint("↩", "apply")
            KbdHint("⇥", "edit")
            KbdHint("esc", "close")
        }
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chromeTint)
    }
}
