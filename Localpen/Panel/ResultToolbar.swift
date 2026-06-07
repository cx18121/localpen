import SwiftUI

struct ResultToolbar: View {
    enum Mode { case streaming, result, editing }

    let action: Action
    let mode: Mode
    var justCopied: Bool = false
    var isCreate: Bool = false
    var canDiff: Bool = false
    var diffOn: Bool = false
    var onAccept: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.s6) {
            Text(action.pillLabel)
                .font(Typography.pill)
                .foregroundStyle(Tokens.textSoft)
                .lineLimit(1)            // never let a tight toolbar wrap the pill into a vertical letter-stack
                .fixedSize()
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
                } else if canDiff {
                    // Transform result with the change-view available: ⌥D takes the slot the
                    // ⌘C hint would — the 400pt panel can't show the pill + 4 rigid hints
                    // without squeezing the pill. ⌘C still copies, just unhinted here.
                    KbdHint("⌥D", diffOn ? "clean" : "changes")
                    KbdHint("⌘↩", "accept")
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
