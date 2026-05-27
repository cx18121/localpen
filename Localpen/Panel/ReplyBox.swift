import SwiftUI

/// A reply field shared by the conversation surface and the one-shot result view.
/// Mirrors CustomPromptView's rail-field treatment: a borderless GrowingTextEditor
/// with a left rail (hairline at rest, accent when focused), Return submits /
/// ⇧Return newline, and a keyboard-hint footer.
///
/// `autoFocus` is the load-bearing parameter: ConversationView passes `true`
/// (focus immediately so the user can type a follow-up), while the result view
/// passes `false` so the result's fast path stays intact — when the box isn't
/// focused, the panel's `.result` keys (Return = accept, ⌘C = copy, Tab = edit,
/// Esc = back) still reach `handleKeyDown`. The box is click-to-focus there.
struct ReplyBox: View {
    @Binding var text: String
    var autoFocus: Bool
    var placeholder: String = "reply to keep refining…"
    var showHints: Bool = true
    let onSubmit: (String) -> Void

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Tokens.textFaint)
                        .font(Typography.menuRow)
                        .padding(.top, GrowingTextEditor.topInset)
                        .allowsHitTesting(false)
                }
                GrowingTextEditor(
                    text: $text,
                    isFocused: $isFocused,
                    autoFocus: autoFocus,
                    fontSize: 14,
                    onSubmit: { raw in onSubmit(raw) }
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 22)
            }
            .padding(.vertical, Spacing.s4)
            .padding(.horizontal, Spacing.s7)

            if showHints {
                Hairline()

                HStack(spacing: Spacing.s5) {
                    KbdHint("↩", "send")
                    KbdHint("⇧↩", "newline")
                    KbdHint("esc", "close")
                }
                .padding(.horizontal, Spacing.s6)
                .padding(.vertical, Spacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.chromeTint)
            }
        }
    }
}
