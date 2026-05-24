import SwiftUI

/// Pure renderer. Keyboard nav is handled in `PanelController.handleKeyDown`
/// via the panel's `keyDown(with:)` override — no `@FocusState`, no
/// `.onKeyPress`. Click + hover update `focusedIndex` for visual continuity.
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
                    if hovering { controller.focusedActionIndex = i }
                }
            }
        }
        .padding(.vertical, Spacing.s2)
    }
}
