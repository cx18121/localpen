import SwiftUI

extension View {
    /// The panel's footer / toolbar chrome band: a keycap-hint (or action) cluster on a
    /// translucent `chromeTint` strip, inset `s6` horizontal / `s3` vertical, full width.
    /// One source so every footer reads as the same band — the panel footer, result
    /// toolbar, reply/custom-prompt footers, the profile footer, and the hub footer.
    func panelFooterChrome() -> some View {
        self
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.chromeTint)
    }
}
