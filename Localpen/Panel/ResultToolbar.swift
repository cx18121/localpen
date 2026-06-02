import SwiftUI

struct ResultToolbar: View {
    enum Mode { case streaming, result, editing }

    let action: Action
    let mode: Mode
    var justCopied: Bool = false
    var isCreate: Bool = false
    var onAccept: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.s6) {
            Text(action.pillLabel)
                .font(Typography.pill)
                .foregroundStyle(Tokens.textSoft)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 3)
                .background(Tokens.rowHighlight)
                .clipShape(Capsule())

            Spacer()

            switch mode {
            case .streaming:
                KbdHint("esc", "cancel")

            case .result:
                if isCreate {
                    if justCopied { copiedLabel } else { KbdHint("⌘↩", "copy reply") }
                    KbdHint("esc", "back")
                } else {
                    KbdHint("⌘↩", "accept")
                    if justCopied { copiedLabel } else { KbdHint("⌘C", "copy") }
                    KbdHint("esc", "back")
                }

            case .editing:
                KbdHint("↩", "save")
                KbdHint("esc", "cancel")
            }
        }
        .panelFooterChrome()
    }

    /// Transient copy confirmation. No glyph/emoji in chrome (PRODUCT voice); the accent
    /// is one of the few sanctioned accent notes left after the neutral-focus polish.
    private var copiedLabel: some View {
        Text("copied").font(Typography.pill).foregroundStyle(Tokens.accent)
    }
}
