import SwiftUI

struct ActionMenuView: View {
    let onPick: (Action) -> Void

    @State private var focusedIndex: Int = 1 // Polish default per DESIGN.md §S4
    @FocusState private var menuFocused: Bool

    private let items: [Action] = Action.fixed + [.custom("")]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                ActionRow(action: items[i], isFocused: focusedIndex == i)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedIndex = i
                        onPick(items[i])
                    }
                    .onHover { hovering in
                        if hovering { focusedIndex = i }
                    }
            }
        }
        .padding(.vertical, 6)
        .focusable(true)
        .focused($menuFocused)
        .focusEffectDisabled()
        .onAppear { menuFocused = true }
        .onKeyPress(.upArrow) {
            focusedIndex = (focusedIndex - 1 + items.count) % items.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            focusedIndex = (focusedIndex + 1) % items.count
            return .handled
        }
        .onKeyPress(.return) {
            onPick(items[focusedIndex])
            return .handled
        }
    }
}
