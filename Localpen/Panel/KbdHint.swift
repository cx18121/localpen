import SwiftUI

/// A keyboard-shortcut hint: the key glyph(s) in the mono kbd style, the label
/// in regular text (per DESIGN.md §2.3). Used in the footer, result toolbar,
/// and custom-prompt footer so all shortcut helpers read consistently.
struct KbdHint: View {
    let keys: String
    let label: String

    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }

    var body: some View {
        HStack(spacing: Spacing.s1) {
            Text(keys)
                .font(Typography.kbdGlyph)
                .foregroundStyle(Tokens.textSoft)
            Text(label)
                .font(Typography.footerHint)
                .foregroundStyle(Tokens.textMute)
        }
        .fixedSize()
    }
}
