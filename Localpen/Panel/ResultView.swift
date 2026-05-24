import SwiftUI

/// Streaming display + edit-on-click. Keyboard handling lives in
/// `PanelController.handleKeyDown`; this view is purely visual.
struct ResultView: View {
    @Binding var text: String
    let isStreaming: Bool
    let isEditing: Bool
    var onClickToEdit: (() -> Void)? = nil

    @FocusState private var editorFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(Typography.result)
                    .foregroundStyle(Tokens.text)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 320)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.vertical, Spacing.s6)
                    .onAppear { editorFocused = true }
            } else if isStreaming && text.isEmpty {
                // Subtle pulse while the model warms up before the first token lands.
                GeneratingIndicator()
                    .frame(minHeight: 96, maxHeight: 320, alignment: .topLeading)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.vertical, Spacing.s6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            HStack(alignment: .top, spacing: 0) {
                                Text(text)
                                    .font(Typography.result)
                                    .foregroundStyle(Tokens.text)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                if isStreaming {
                                    StreamingCaret()
                                        .padding(.top, 3)
                                }
                            }
                            // Invisible anchor for scroll-to-bottom.
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .frame(minHeight: 96, maxHeight: 320)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.vertical, Spacing.s6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isStreaming { onClickToEdit?() }
                    }
                    .onChange(of: text) { _, _ in
                        if isStreaming {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct GeneratingIndicator: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: Spacing.s2) {
            Text("Generating")
                .font(Typography.body)
                .foregroundStyle(Tokens.textMute)
            StreamingCaret()
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                opacity = 1.0
            }
        }
    }
}
