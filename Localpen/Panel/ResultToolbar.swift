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
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 3)
                .background(Tokens.accentTint)
                .clipShape(Capsule())

            Spacer()

            switch mode {
            case .streaming:
                KbdHint("esc", "cancel")

            case .result:
                if isCreate {
                    KbdHint("⌘↩", "copy reply")
                    KbdHint("esc", "back")
                } else {
                    KbdHint("⌘↩", "accept")
                    if justCopied {
                        Text("copied ✓")
                            .font(Typography.pill)
                            .foregroundStyle(Tokens.accent)
                    } else {
                        KbdHint("⌘C", "copy")
                    }
                    KbdHint("esc", "back")
                }

            case .editing:
                KbdHint("↩", "save")
                KbdHint("esc", "cancel")
            }
        }
        .padding(.horizontal, Spacing.s6)
        .padding(.vertical, Spacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chromeTint)
    }
}
