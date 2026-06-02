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

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            // Clean borderless field — no rail or box, just the text and a
            // placeholder, like a native search field. Focus reads from the caret.
            GrowingField(text: $text, placeholder: "Type or paste text to transform…",
                         autoFocus: autoFocus, focusTick: focusTick)
                .padding(.vertical, Spacing.s3)
                .frame(minHeight: 40, alignment: .topLeading)

            if let app = sourceAppName {
                Text("from \(app)")
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textMute)
            }
        }
        .padding(Spacing.s7)
    }
}
