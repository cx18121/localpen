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
                .font(.system(size: 13, weight: isFocused ? .medium : .regular))
                .foregroundStyle(isFocused ? Tokens.text : Tokens.textSoft)
                .padding(.leading, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32)
        .background(isFocused ? Tokens.accentTint : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
    }
}
