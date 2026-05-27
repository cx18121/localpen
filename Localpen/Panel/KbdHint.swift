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
        HStack(spacing: Spacing.s2) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Tokens.textSoft)
                .frame(minWidth: 16)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Tokens.rowHighlight)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.hairline, lineWidth: 1))
                )
            Text(label)
                .font(Typography.footerHint)
                .foregroundStyle(Tokens.textSoft)
        }
        .fixedSize()
    }
}
