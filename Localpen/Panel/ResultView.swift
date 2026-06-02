import SwiftUI

/// Streaming display + edit-on-click. Keyboard handling lives in
/// `PanelController.handleKeyDown`; this view is purely visual.
struct ResultView: View {
    @Binding var text: String
    let isStreaming: Bool
    let isEditing: Bool
    var onClickToEdit: (() -> Void)? = nil

    @FocusState private var editorFocused: Bool

    // One source for the result region's dimensions (DESIGN §3.4): min height so a
    // short result still reads as a panel, max so a long one scrolls instead of
    // overrunning the screen. Repeated across the edit / warm-up / display branches.
    private static let minBodyHeight: CGFloat = 96
    private static let maxBodyHeight: CGFloat = 320
    private static let bodyLineSpacing: CGFloat = Spacing.s1

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(Typography.result)
                    .foregroundStyle(Tokens.text)
                    .lineSpacing(Self.bodyLineSpacing)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: Self.minBodyHeight, maxHeight: Self.maxBodyHeight)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.vertical, Spacing.s6)
                    .onAppear { editorFocused = true }
            } else if isStreaming && text.isEmpty {
                // Subtle pulse while the model warms up before the first token lands.
                GeneratingIndicator()
                    .frame(minHeight: Self.minBodyHeight, maxHeight: Self.maxBodyHeight, alignment: .topLeading)
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
                                    .lineSpacing(Self.bodyLineSpacing)
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
                    .frame(minHeight: Self.minBodyHeight, maxHeight: Self.maxBodyHeight)
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
            withAnimation(Motion.warmupPulse.repeatForever()) {
                opacity = 1.0
            }
        }
    }
}
