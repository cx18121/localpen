import SwiftUI

/// The canonical "nothing here yet" panel for any list surface. Centered icon,
/// title at menu-row weight, soft caption underneath. Used by the recents list
/// and the profile cold-start state, so they read as the same family.
struct EmptyStateView: View {
    let icon: String                   // SF Symbol
    let title: String
    var caption: String? = nil

    var body: some View {
        VStack(spacing: Spacing.s3) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.textFaint)
            Text(title)
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.textMute)
            if let caption {
                Text(caption)
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.s6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s8 + Spacing.s6)
    }
}
