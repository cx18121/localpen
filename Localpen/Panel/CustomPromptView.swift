import SwiftUI

struct CustomPromptView: View {
    let action: Action
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @State private var isFocused = false

    private var isRespond: Bool {
        if case .respond = action { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.s3) {
                Text("›")
                    .foregroundStyle(Tokens.accent)
                    .font(.system(size: 14, weight: .medium))

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(isRespond ? "How should I reply?  (optional)" : "Type a custom prompt…")
                            .foregroundStyle(Tokens.textFaint)
                            .font(Typography.menuRow)
                            .padding(.top, GrowingTextEditor.topInset)
                            .allowsHitTesting(false)
                    }
                    // AppKit-backed editor: reliable auto-focus on appear (the
                    // SwiftUI @FocusState/onAppear path dropped focus during the
                    // panel's animated state swap), Return submits, ⇧Return adds
                    // a newline, Esc bubbles to the panel for "back".
                    GrowingTextEditor(
                        text: $text,
                        isFocused: $isFocused,
                        autoFocus: true,
                        fontSize: 14,
                        onSubmit: { raw in
                            onSubmit(raw)
                        }
                    )
                    // Hug content height so the prompt box stays compact and
                    // grows with the text, instead of stretching to fill the
                    // panel (nothing below it absorbs the height here).
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 22)
                }
            }
            .padding(.horizontal, Spacing.s7)
            .padding(.vertical, Spacing.s4)

            Hairline()

            HStack(spacing: Spacing.s5) {
                KbdHint("↩", "submit")
                KbdHint("⇧↩", "newline")
                KbdHint("esc", "back")
            }
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.chromeTint)
        }
    }
}
