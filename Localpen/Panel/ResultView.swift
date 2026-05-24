import SwiftUI

/// Streaming display + edit-on-click. All keyboard handling for the result
/// view lives in `PanelController.handleKeyDown` — including ⌘↩ / Esc / Return
/// in editing mode — so this view is purely visual.
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
            } else {
                ScrollView {
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
                }
                .frame(minHeight: 96, maxHeight: 320)
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s6)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isStreaming { onClickToEdit?() }
                }
            }
        }
    }
}
