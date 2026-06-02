import SwiftUI

/// A keyboard-shortcut hint: the key glyph(s) in a small keycap chip, the label
/// in regular text. Used in the footer, result toolbar, and custom-prompt footer
/// so all shortcut helpers read consistently. The glyph face is `Typography.kbdGlyph`
/// (rounded·semibold — the legibility polish, not the older mono spec).
struct KbdHint: View {
    let keys: String
    let label: String

    /// Keycap corner radius — smaller than `innerRadius` so the chip reads as a tight key.
    private static let capRadius: CGFloat = 5

    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    var body: some View {
        HStack(spacing: Spacing.s2) {
            Text(keys)
                .font(Typography.kbdGlyph)
                .foregroundStyle(Tokens.textSoft)
                .frame(minWidth: 16)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Self.capRadius)
                        .fill(Tokens.rowHighlight)
                        .overlay(RoundedRectangle(cornerRadius: Self.capRadius).stroke(Tokens.hairline, lineWidth: 1))
                )
            Text(label)
                .font(Typography.footerHint)
                .foregroundStyle(Tokens.textSoft)
        }
        .fixedSize()
    }
}
