import SwiftUI

/// Pure renderer. Keyboard nav is handled in `PanelController.handleKeyDown`
/// via the panel's `keyDown(with:)` override. Click + hover update the
/// controller's `focusedActionIndex` for visual continuity — but hover only
/// wins when the user's last input was actually a mouse event, so an idle
/// cursor parked over a different row can't fight with arrow keys.
struct ActionMenuView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PanelController.menuItems.indices, id: \.self) { i in
                ActionRow(
                    action: PanelController.menuItems[i],
                    isFocused: controller.focusedActionIndex == i
                )
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
        .padding(.vertical, Spacing.s2)
    }
}
