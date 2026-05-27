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
            // Same borderless "rail field" as InputEditor: a left rail that is a
            // faint hairline at rest and the accent focus rail when active, so the
            // compose field reads as one system with the type/paste field and the
            // action menu (DESIGN §2.5/§S5).
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
            .padding(.leading, Spacing.s5)
            .padding(.vertical, Spacing.s4)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? Tokens.accent : Tokens.hairline)
                    .frame(width: isFocused ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .padding(.horizontal, Spacing.s7)

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
