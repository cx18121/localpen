import SwiftUI

struct CustomPromptView: View {
    let action: Action
    let onSubmit: (String) -> Void

    @State private var text: String = ""

    private var isRespond: Bool {
        if case .respond = action { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clean borderless field, consistent with InputEditor — no rail. The
            // AppKit-backed editor gives reliable auto-focus on appear (the SwiftUI
            // @FocusState/onAppear path dropped focus during the panel's animated state
            // swap), Return submits, ⇧Return newline, Esc bubbles to the panel for "back".
            GrowingField(
                text: $text,
                placeholder: isRespond ? "How should I reply?  (optional)" : "Type a custom prompt…",
                autoFocus: true,
                onSubmit: { raw in onSubmit(raw) }
            )
            // Hug content height so the prompt box stays compact and grows with the
            // text, instead of stretching to fill the panel (nothing below absorbs it).
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 22)
            .padding(.vertical, Spacing.s4)
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
