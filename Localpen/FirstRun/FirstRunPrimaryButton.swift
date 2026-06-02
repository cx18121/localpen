import SwiftUI

/// The first-run flow's single primary call-to-action: a prominent accent-tinted button
/// ("Open System Settings", "Download", "Retry"). One definition so the three onboarding
/// screens render an identical CTA — padding, tint, and type can't drift per screen.
struct FirstRunPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.body)
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s3)
        }
        .buttonStyle(.borderedProminent)
        .tint(Tokens.accent)
    }
}
