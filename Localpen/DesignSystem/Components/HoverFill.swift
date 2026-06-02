import SwiftUI

/// The app's neutral hover highlight: a `rowHighlight` fill that fades in while the pointer
/// is over the view. Owns its own hover state so tappable surfaces (MenuRow, OutlineButton,
/// future rows) don't each re-declare `@State hover` + `.onHover` + the magic fade opacity —
/// the one place the hover treatment is defined, so it can't drift between components.
struct HoverFill: ViewModifier {
    var radius: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Tokens.rowHighlight)
                    .opacity(hover ? 0.7 : 0)
            )
            .onHover { hover = $0 }
    }
}

extension View {
    /// Apply the canonical neutral hover highlight, matched to the surface's corner radius.
    func hoverFill(radius: CGFloat) -> some View { modifier(HoverFill(radius: radius)) }
}
