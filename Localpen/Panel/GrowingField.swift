import SwiftUI

/// The canonical borderless growing input: a `textFaint` placeholder overlaid on a
/// `GrowingTextEditor`, aligned to the editor's top inset. One source for the placeholder
/// treatment and field font that AskInput, ReplyBox, InputEditor, and CustomPromptView
/// all share — callers add their own padding / footer / frame chrome around it.
///
/// `autoFocus`, `focusTick`, and `onSubmit` pass straight through to `GrowingTextEditor`:
/// with `onSubmit` set the field is a submit field (Return submits, ⇧Return newline, Esc
/// bubbles to the panel); with it nil, Tab/Esc blur focus back to the action menu.
struct GrowingField: View {
    @Binding var text: String
    let placeholder: String
    var autoFocus: Bool = false
    var focusTick: Int = 0
    var onSubmit: ((String) -> Void)? = nil
    /// When set, typing `[[` or `@` offers a completion list of these titles (W2 mention input).
    var mentionTitles: (() -> [String])? = nil

    @State private var isFocused = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Typography.menuRow)
                    .foregroundStyle(Tokens.textFaint)
                    .padding(.top, GrowingTextEditor.topInset)
                    .allowsHitTesting(false)
            }
            GrowingTextEditor(
                text: $text,
                isFocused: $isFocused,
                autoFocus: autoFocus,
                focusTick: focusTick,
                onSubmit: onSubmit,
                mentionTitles: mentionTitles
            )
        }
    }
}
