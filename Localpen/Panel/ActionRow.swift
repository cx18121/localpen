import SwiftUI

/// A single action label. The focus highlight (tint + rail) is drawn and
/// animated by ActionMenuView as one sliding element; this view only renders
/// the label and its focused color/weight.
struct ActionRow: View {
    let action: Action
    let isFocused: Bool

    private var isCreate: Bool { action.operationClass == .create }

    var body: some View {
        Text(action.label)
            .font(isFocused ? Typography.menuRowFocused : Typography.menuRow)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lead clears the highlight inset (s4) + rail (2) + gap (s5) so the
            // label sits just right of the rail.
            .padding(.leading, Spacing.s4 + 2 + Spacing.s5)
            .padding(.trailing, Spacing.s5)
            .animation(Motion.focusMove, value: isFocused)
    }

    private var labelColor: Color {
        if isCreate {
            return isFocused ? Tokens.createAccent : Tokens.createAccent.opacity(0.75)
        }
        return isFocused ? Tokens.text : Tokens.textSoft
    }
}
