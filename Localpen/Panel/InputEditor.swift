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
    /// True during the instant-open capture window — show a quiet "Reading
    /// selection…" hint instead of the type-prompt, so the empty→text moment
    /// reads as deliberate rather than a flash of the wrong placeholder.
    var isCapturing: Bool = false

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            // Clean borderless field — no rail or box, just the text and a
            // placeholder, like a native search field. Focus reads from the caret.
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(isCapturing ? "Reading selection…" : "Type or paste text to transform…")
                        .font(Typography.selection)
                        .foregroundStyle(Tokens.textFaint)
                        .padding(.top, GrowingTextEditor.topInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
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
