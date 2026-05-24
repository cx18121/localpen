import SwiftUI

struct CustomPromptView: View {
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    @State private var text: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text("›")
                    .foregroundStyle(Tokens.accent)
                    .font(.system(size: 16, weight: .semibold))

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type a custom prompt…")
                            .foregroundStyle(Tokens.textFaint)
                            .font(.system(size: 13))
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($inputFocused)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 40, maxHeight: 96)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Hairline()

            HStack(spacing: 14) {
                Text("↩ submit")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
                Text("⇧↩ newline")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
                Text("esc back")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textMute)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.panelBG2)
        }
        .onAppear { inputFocused = true }
        .onKeyPress(.return, phases: .down) { _ in
            if NSEvent.modifierFlags.contains(.shift) {
                return .ignored
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .handled }
            onSubmit(trimmed)
            return .handled
        }
    }
}
