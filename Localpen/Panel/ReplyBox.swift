import SwiftUI

/// A reply field shared by the conversation surface and the one-shot result view.
/// A borderless `GrowingField` (no rail — the de-blue pass removed it): Return submits /
/// ⇧Return newline, with a keyboard-hint footer.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GrowingField(text: $text, placeholder: placeholder, autoFocus: autoFocus,
                         onSubmit: onSubmit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 22)
                .padding(.vertical, Spacing.s4)
                .padding(.horizontal, Spacing.s7)

            if showHints {
                Hairline()

                HStack(spacing: Spacing.s5) {
                    KbdHint("↩", "send")
                    KbdHint("⇧↩", "newline")
                    KbdHint("esc", "close")
                }
                .panelFooterChrome()
            }
        }
    }
}
