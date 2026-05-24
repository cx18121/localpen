import SwiftUI

struct ActionRow: View {
    let action: Action
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isFocused ? Tokens.accent : Color.clear)
                .frame(width: 2)

            Text(action.label)
                .font(isFocused ? Typography.menuRowFocused : Typography.menuRow)
                .foregroundStyle(isFocused ? Tokens.text : Tokens.textSoft)
                .padding(.leading, Spacing.s4)
                .padding(.vertical, Spacing.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32)
        .background(isFocused ? Tokens.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.innerRadius))
        .padding(.horizontal, Spacing.s4)
        .animation(Motion.focusMove, value: isFocused)
    }
}
