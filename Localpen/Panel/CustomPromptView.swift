import SwiftUI

struct CustomPromptView: View {
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.s3) {
                Text("›")
                    .foregroundStyle(Tokens.accent)
                    .font(.system(size: 14, weight: .medium))

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type a custom prompt…")
                            .foregroundStyle(Tokens.textFaint)
                            .font(Typography.menuRow)
                            .padding(.top, Spacing.s3)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($inputFocused)
                        .font(Typography.menuRow)
                        .foregroundStyle(Tokens.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 40, maxHeight: 96)
                }
            }
            .padding(.horizontal, Spacing.s7)
            .padding(.vertical, Spacing.s4)

            Hairline()

            HStack(spacing: Spacing.s6) {
                hint("↩ submit")
                hint("⇧↩ newline")
                hint("esc back")
            }
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.panelBG2)
        }
        .onAppear { inputFocused = true }
        // Plain Return submits; Shift+Return inserts a newline.
        // We use the SwiftUI handler here (not the panel-level one) because
        // the TextEditor is the first responder while focused.
        .onKeyPress(.return, phases: .down) { keyPress in
            if keyPress.modifiers.contains(.shift) { return .ignored }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .handled }
            onSubmit(trimmed)
            return .handled
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typography.footerHint)
            .foregroundStyle(Tokens.textMute)
    }
}
