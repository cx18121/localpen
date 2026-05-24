import SwiftUI

/// Editable input text box used in .empty / .captured states.
/// Bound to PanelController.inputText so user edits persist across the
/// session and get applied when picking an action.
///
/// Click-to-focus. NSTextView (under TextEditor) handles typing + caret
/// movement while focused. ESC (via FloatingPanel.cancelOperation) blurs
/// back to the menu so arrow keys regain action-row navigation.
struct InputEditor: View {
    @Binding var text: String
    let sourceAppName: String?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type or paste text to transform…")
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.textFaint)
                        .italic()
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .font(Typography.selection)
                    .foregroundStyle(Tokens.text)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 64, maxHeight: 128)
                    // ESC in a focused editor: blur it. Panel-level ESC then
                    // dismisses on a second press.
                    .onKeyPress(.escape) {
                        focused = false
                        return .handled
                    }
            }
            .background(Tokens.panelBG2)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.innerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Spacing.innerRadius)
                    .stroke(focused ? Tokens.accent : Tokens.hairline, lineWidth: 1)
            )

            if let app = sourceAppName {
                Text("from \(app)")
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(Spacing.s7)
    }
}
