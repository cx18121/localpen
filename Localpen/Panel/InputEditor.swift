import SwiftUI

/// Editable input text box used in .empty / .captured states.
/// Bound to PanelController.inputText so user edits persist across the
/// session and get applied when picking an action.
///
/// Uses GrowingTextEditor (a self-sizing NSTextView) so the box grows to fit
/// its content with no scrolling and no clipping. Click the text to focus;
/// Tab/Esc blur back to the action menu.
struct InputEditor: View {
    @Binding var text: String
    let sourceAppName: String?
    /// Auto-focus on open. True only in the empty state (you must type anyway);
    /// false when text was captured, so the menu keeps focus and Return still
    /// picks an action immediately (Tab/click to edit the text).
    var autoFocus: Bool = false
    /// Bumped by the controller (Tab from the menu) to pull focus here.
    var focusTick: Int = 0

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            // Borderless "rail field": no box or fill — just a left rail that
            // reads as a faint hairline at rest and the accent focus rail when
            // active, matching the action menu's focus language (DESIGN §2.5/§S5).
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type or paste text to transform…")
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.textFaint)
                        .padding(.top, GrowingTextEditor.topInset)
                        .allowsHitTesting(false)
                }
                GrowingTextEditor(
                    text: $text,
                    isFocused: $isFocused,
                    autoFocus: autoFocus,
                    focusTick: focusTick,
                    fontSize: 14
                )
                .frame(minHeight: 20)
            }
            .padding(.leading, Spacing.s5)
            .padding(.vertical, Spacing.s3)
            .frame(minHeight: 40, alignment: .topLeading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? Tokens.accent : Tokens.hairline)
                    .frame(width: isFocused ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)

            if let app = sourceAppName {
                Text("from \(app)")
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(Spacing.s7)
    }
}
