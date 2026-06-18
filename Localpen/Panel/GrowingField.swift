import SwiftUI
import AppKit

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
    /// When set, typing `[[` or `@` offers a dropdown of these titles (W2 mention input).
    var mentionTitles: (() -> [String])? = nil

    @State private var isFocused = false
    @StateObject private var mentions = MentionCompletionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
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
                    mentionTitles: mentionTitles,
                    mentionModel: mentionTitles != nil ? mentions : nil
                )
            }
            // Inline dropdown directly under the field (the notch panel is a non-key window,
            // so AppKit's native completion popup never renders — we draw our own).
            if mentions.isActive {
                MentionSuggestionList(model: mentions) { idx in
                    mentions.selected = idx
                    pickHostTextView()?.acceptMention()
                }
            }
        }
    }

    /// The hosting NSTextView, for mouse-pick insertion (keyboard Return routes through the
    /// view's own key handling). Found via the key window's first responder.
    private func pickHostTextView() -> GrowingNSTextView? {
        NSApp.keyWindow?.firstResponder as? GrowingNSTextView
            ?? NSApp.windows.compactMap { $0.firstResponder as? GrowingNSTextView }.first
    }
}
