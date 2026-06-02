import SwiftUI

/// Grouped action menu: a REVISE group (the five transforms), a CREATE group
/// (Respond), and Custom below a divider. Keyboard nav (in
/// PanelController.handleKeyDown) treats the action ROWS as one flat list;
/// headers/divider are visual only. The sliding highlight's vertical offset is
/// computed per row because headers break the uniform row grid.
struct ActionMenuView: View {
    @Bindable var controller: PanelController

    /// Row under the pointer — a subtle, instant hover lift (no slide animation,
    /// distinct from the keyboard focus fill). Doesn't move keyboard focus.
    @State private var hoveredIndex: Int? = nil

    private let rowHeight: CGFloat = 34
    private let headerHeight: CGFloat = 24
    private let headerBottomPad: CGFloat = 4
    private let dividerHeight: CGFloat = 13
    /// Full rendered height of a group header (frame + its bottom padding).
    private var headerTotal: CGFloat { headerHeight + headerBottomPad }

    private var respondIdx: Int { Action.fixed.count }            // 5
    private var askIdx: Int { Action.fixed.count + 1 }            // 6
    private var customIdx: Int { Action.fixed.count + 2 }         // 7
    private var reviseRange: Range<Int> { 0..<Action.fixed.count }

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
        if index == askIdx { return y }                // Ask sits below Respond, above divider
        y += rowHeight                                 // past Ask
        y += dividerHeight                             // divider
        return y                                       // Custom row
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Clean neutral focus highlight — a soft rounded fill, no blue accent
            // rail. Slides between rows on keyboard nav.
            RoundedRectangle(cornerRadius: Spacing.innerRadius)
                .fill(Tokens.rowHighlight)
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
                row(askIdx)
                Hairline().padding(.horizontal, Spacing.s4).padding(.vertical, Spacing.s2)
                row(customIdx)
            }
        }
        .padding(.vertical, Spacing.s2)
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.sectionHeader)
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
            .background(
                RoundedRectangle(cornerRadius: Spacing.innerRadius)
                    .fill(Tokens.rowHighlight)
                    .padding(.horizontal, Spacing.s4)
                    // Only the hovered, non-focused, enabled row gets the lift (matches
                    // HoverFill's 0.7 so the hover feels identical to MenuRow-based lists).
                    .opacity(hoveredIndex == i && controller.focusedActionIndex != i && !disabled ? 0.7 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard !disabled else { return }
                controller.focusedActionIndex = i
                controller.pick(action)
            }
            .onHover { hovering in
                if hovering { hoveredIndex = i }
                else if hoveredIndex == i { hoveredIndex = nil }
            }
    }
}
