import SwiftUI

struct ResultView: View {
    @Binding var text: String
    let isStreaming: Bool
    let isEditing: Bool
    var onClickToEdit: (() -> Void)? = nil
    var onSubmitEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    @FocusState private var editorFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.text)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 320)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .onAppear { editorFocused = true }
                    .onKeyPress(.return, phases: .down) { _ in
                        if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                        onSubmitEdit?()
                        return .handled
                    }
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        Text(text)
                            .font(.system(size: 14))
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
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isStreaming { onClickToEdit?() }
                }
            }
        }
    }
}
