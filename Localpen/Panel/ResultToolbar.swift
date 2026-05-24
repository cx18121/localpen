import SwiftUI

struct ResultToolbar: View {
    enum Mode { case streaming, result, editing }

    let action: Action
    let mode: Mode
    var onAccept: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(actionPillLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Tokens.accentTint)
                .clipShape(Capsule())

            Spacer()

            switch mode {
            case .streaming:
                Text("esc cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)

            case .result:
                Text("esc back")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
                Text("⌘↩ accept")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)

            case .editing:
                Text("↩ submit edit")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
                Text("esc cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.panelBG2)
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
