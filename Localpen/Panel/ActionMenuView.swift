import SwiftUI

/// Grouped action menu: a REVISE group (the five transforms), a CREATE group
/// (Respond), and Custom below a divider. Keyboard nav (in
/// PanelController.handleKeyDown) treats the action ROWS as one flat list;
/// headers/divider are visual only. The sliding highlight's vertical offset is
/// computed per row because headers break the uniform row grid.
struct ActionMenuView: View {
    @Bindable var controller: PanelController

    private let rowHeight: CGFloat = 38
    private let headerHeight: CGFloat = 26
    private let headerBottomPad: CGFloat = 4
    private let dividerHeight: CGFloat = 13
    /// Full rendered height of a group header (frame + its bottom padding).
    private var headerTotal: CGFloat { headerHeight + headerBottomPad }

    private var respondIdx: Int { Action.fixed.count }                        // 5
    private var customIdx: Int { Action.fixed.count + 1 }                     // 6
    private var reviseRange: Range<Int> { 0..<Action.fixed.count }            // 0..4

    /// Top offset of the highlight for a given row index, accounting for the
    /// headers and divider physically above it.
    private func highlightOffset(for index: Int) -> CGFloat {
        var y = headerTotal                            // REVISE header (frame + bottom pad)
        if index < respondIdx {                        // a revise row
            return y + CGFloat(index) * rowHeight
        }
        y += CGFloat(Action.fixed.count) * rowHeight   // past the revise rows
        y += headerTotal                               // CREATE header
        if index == respondIdx { return y }
        y += rowHeight                                 // past Respond
        y += dividerHeight                             // divider
        return y                                       // Custom row
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Spacing.innerRadius)
                .fill(Tokens.accentTint)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Tokens.accent).frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.innerRadius))
                .frame(height: rowHeight)
                .padding(.horizontal, Spacing.s4)
                .offset(y: highlightOffset(for: controller.focusedActionIndex))
                .animation(Motion.focusSlide, value: controller.focusedActionIndex)
                .opacity(controller.focusedActionIndex == respondIdx && !controller.respondEnabled ? 0 : 1)

            VStack(alignment: .leading, spacing: 0) {
                groupHeader("Revise")
                ForEach(reviseRange, id: \.self) { i in row(i) }
                groupHeader("Create")
                row(respondIdx)
                Hairline().padding(.horizontal, Spacing.s4).padding(.vertical, 6)
                row(customIdx)
            }
        }
        .padding(.vertical, Spacing.s2)
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Tokens.textFaint)
            .frame(height: headerHeight, alignment: .bottomLeading)
            .padding(.horizontal, Spacing.s7)
            .padding(.bottom, headerBottomPad)
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let action = PanelController.menuItems[i]
        let disabled = (i == respondIdx) && !controller.respondEnabled
        ActionRow(action: action, isFocused: controller.focusedActionIndex == i)
            .frame(height: rowHeight)
            .opacity(disabled ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !disabled else { return }
                controller.focusedActionIndex = i
                controller.pick(action)
            }
            .onHover { hovering in
                if hovering && !disabled && controller.lastInputSource == .mouse {
                    controller.focusedActionIndex = i
                }
            }
    }
}
