import SwiftUI

struct ResultToolbar: View {
    enum Mode { case streaming, result, editing }

    let action: Action
    let mode: Mode
    var onAccept: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.s6) {
            Text(actionPillLabel)
                .font(Typography.pill)
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, 3)
                .background(Tokens.accentTint)
                .clipShape(Capsule())

            Spacer()

            switch mode {
            case .streaming:
                hint("esc cancel")

            case .result:
                hint("esc back")
                hint("⌘↩ accept")

            case .editing:
                hint("↩ submit edit")
                hint("esc cancel")
            }
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

    private var actionPillLabel: String {
        switch action {
        case .proofread:   return "Proofread"
        case .polish:      return "Polish"
        case .moreFormal:  return "More formal"
        case .moreCasual:  return "More casual"
        case .shorter:     return "Shorter"
        case .custom:      return "Custom"
        }
    }
}
