import SwiftUI

/// A standard back-navigation bar: small chevron + title, tappable, soft-toned.
/// Used at the top of any detail surface that pushes from a list (profile, future
/// thread detail, future settings sub-pages).
struct BackBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(Typography.menuRow)
            }
            .foregroundStyle(Tokens.textSoft)
            .padding(.horizontal, Spacing.s6)
            .padding(.top, Spacing.s5)
            .padding(.bottom, Spacing.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
