import SwiftUI

/// The canonical tappable row for any list-like surface in the notch: leading
/// SF Symbol, title, optional trailing meta or chevron, neutral hover highlight.
///
/// Used by the recents list, the pinned profile row, future settings rows, etc.
/// Encodes the visual contract once — height, padding, hover treatment, icon
/// frame, chevron weight — so each new surface just picks a `Trailing` and a
/// closure rather than re-styling.
struct MenuRow: View {
    let icon: String                   // SF Symbol name
    let title: String
    var trailing: Trailing = .none
    /// Optional — a non-interactive glance row (no hover lift, no tap) when nil, so a
    /// list of read-only items doesn't present a tappable affordance that does nothing.
    var action: (() -> Void)? = nil

    enum Trailing: Equatable {
        case none
        case text(String)              // e.g. "2h", "learned from 142"
        case chevron
    }

    var body: some View {
        if let action {
            Button(action: action) {
                rowContent
                    .hoverFill(radius: Spacing.innerRadius)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: Spacing.s4) {
            Image(systemName: icon)
                .font(Typography.chromeIcon)
                .foregroundStyle(Tokens.textFaint)
                .frame(width: 18)
            Text(title)
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
            Spacer(minLength: Spacing.s4)
            trailingView
        }
        .padding(.horizontal, Spacing.s5)
        .padding(.vertical, Spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .text(let s):
            Text(s)
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
                .lineLimit(1)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.textFaint)
        }
    }
}
