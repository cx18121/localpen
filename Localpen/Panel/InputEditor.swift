import SwiftUI

/// Editable input text box used in .empty / .captured states.
/// Bound to PanelController.inputText so user edits persist across the
/// session and get applied when picking an action.
///
/// Auto-sizing: SwiftUI's TextEditor doesn't grow to fit its content, so an
/// invisible mirror `Text` drives the height and the editor's own scrolling is
/// disabled. The box grows downward with the content instead of scrolling.
///
/// Click-to-focus. NSTextView (under TextEditor) handles typing + caret
/// movement while focused. ESC (via FloatingPanel.cancelOperation) blurs
/// back to the menu so arrow keys regain action-row navigation.
struct InputEditor: View {
    @Binding var text: String
    let sourceAppName: String?
    /// Bumped by the controller (Tab from the menu) to pull focus here.
    var focusTick: Int = 0

    @FocusState private var focused: Bool

    // Horizontal inset that lines the mirror Text up with the editor's text
    // (TextEditor padding + NSTextContainer line-fragment padding).
    private let hInset: CGFloat = 9
    private let vInset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            // Invisible mirror: sizes to the content so the box grows with it.
            Text(text.isEmpty ? " " : text)
                .font(Typography.selection)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .padding(.horizontal, hInset)
                .padding(.vertical, vInset)
                .opacity(0)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste text to transform…")
                            .font(Typography.selection)
                            .foregroundStyle(Tokens.textFaint)
                            .italic()
                            .padding(.horizontal, hInset)
                            .padding(.vertical, vInset + 2)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    TextEditor(text: $text)
                        .focused($focused)
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.text)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .padding(4)
                        // ESC in a focused editor: blur it. Panel-level ESC then
                        // dismisses on a second press.
                        .onKeyPress(.escape) {
                            focused = false
                            return .handled
                        }
                        // Tab moves focus down to the action menu.
                        .onKeyPress(.tab) {
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
        // Auto-focus on open so you can edit the captured text immediately.
        .onAppear { focused = true }
        // Re-focus when the controller asks (Tab from the menu).
        .onChange(of: focusTick) { _, _ in focused = true }
    }
}
