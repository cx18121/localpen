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
            // Lead clears the highlight inset (s4) + a small gap so the label sits
            // comfortably inside the rounded focus fill.
            .padding(.leading, Spacing.s4 + Spacing.s5)
            .padding(.trailing, Spacing.s5)
            .animation(Motion.focusMove, value: isFocused)
    }

    private var labelColor: Color {
        // Respond (create) sits at full --text even at rest — a quiet monochrome
        // lift that sets it apart without a second accent hue. Every other row is
        // --text-soft at rest, --text when focused.
        if isFocused || isCreate { return Tokens.text }
        return Tokens.textSoft
    }
}
