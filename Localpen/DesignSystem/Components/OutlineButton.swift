import SwiftUI

/// A quiet, native-feeling outlined pill button. Two roles:
/// - `.normal` — neutral text, hairline border, soft hover lift.
/// - `.destructive` — `accentError` text for irreversible actions ("Forget everything").
///
/// Encodes one set of paddings, weights, and radii so footers across the app
/// don't drift in pill chrome.
struct OutlineButton: View {
    let title: String
    var role: Role = .normal
    let action: () -> Void

    @State private var hover = false

    enum Role { case normal, destructive }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.menuRow)
                .foregroundStyle(role == .destructive ? Tokens.accentError : Tokens.textSoft)
                .padding(.horizontal, Spacing.s5)
                .padding(.vertical, Spacing.s3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Tokens.rowHighlight)
                        .opacity(hover ? 0.7 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Tokens.hairline, lineWidth: 0.75)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
