import SwiftUI

/// A subtle inset surface — chromeTint fill, hairline stroke, inner radius —
/// for grouping editable content like the voice-card text editor or any
/// future read-mostly preview. The card pads its own content; callers pass
/// the inner view.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(Spacing.s4)
            .background(
                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                    .fill(Tokens.chromeTint)
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                            .stroke(Tokens.hairline, lineWidth: 0.75)
                    )
            )
    }
}
