import SwiftUI

/// Pure renderer. Keyboard nav is handled in `PanelController.handleKeyDown`
/// via the panel's `keyDown(with:)` override. Click + hover update the
/// controller's `focusedActionIndex` for visual continuity — but hover only
/// wins when the user's last input was actually a mouse event, so an idle
/// cursor parked over a different row can't fight with arrow keys.
///
/// The focus highlight is a single element that *slides* between rows (its
/// vertical offset animates with the focused index) rather than cross-fading
/// per row — crisper, more native.
struct ActionMenuView: View {
    @Bindable var controller: PanelController

    private let rowHeight: CGFloat = 38

    var body: some View {
        ZStack(alignment: .top) {
            // Sliding highlight: accent-tint pill + 2pt accent rail.
            RoundedRectangle(cornerRadius: Spacing.innerRadius)
                .fill(Tokens.accentTint)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Tokens.accent)
                        .frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.innerRadius))
                .frame(height: rowHeight)
                .padding(.horizontal, Spacing.s4)
                .offset(y: CGFloat(controller.focusedActionIndex) * rowHeight)
                .animation(Motion.focusSlide, value: controller.focusedActionIndex)

            VStack(spacing: 0) {
                ForEach(PanelController.menuItems.indices, id: \.self) { i in
                    ActionRow(
                        action: PanelController.menuItems[i],
                        isFocused: controller.focusedActionIndex == i
                    )
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.focusedActionIndex = i
                        controller.pick(PanelController.menuItems[i])
                    }
                    .onHover { hovering in
                        if hovering && controller.lastInputSource == .mouse {
                            controller.focusedActionIndex = i
                        }
                    }
                }
            }
        }
        .padding(.vertical, Spacing.s2)
    }
}
