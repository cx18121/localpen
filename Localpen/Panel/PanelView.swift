import SwiftUI
import AppKit

struct PanelView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.state {
            case .hidden:
                EmptyView()

            case .empty:
                EmptySelectionHeader()
                Hairline()
                CustomPromptView(
                    onSubmit: { controller.submitCustomPrompt($0) },
                    onEscape: { controller.dismiss() }
                )

            case .captured(let sel):
                SelectionBlock(selection: sel)
                Hairline()
                ActionMenuView(onPick: { controller.pick($0) })
                Hairline()
                PanelFooter()

            case .customPrompt(let sel):
                if let sel = sel {
                    SelectionBlock(selection: sel)
                    Hairline()
                }
                CustomPromptView(
                    onSubmit: { controller.submitCustomPrompt($0) },
                    onEscape: { controller.handleEscape() }
                )

            case .generating(let sel, let action, let partial):
                if let sel = sel {
                    SelectionBlock(selection: sel)
                    Hairline()
                }
                ResultView(
                    text: .constant(partial),
                    isStreaming: true,
                    isEditing: false
                )
                Hairline()
                ResultToolbar(action: action, mode: .streaming)

            case .result(let sel, let action, let finalText, let isEditing):
                if let sel = sel {
                    SelectionBlock(selection: sel)
                    Hairline()
                }
                ResultView(
                    text: Binding(
                        get: { finalText },
                        set: { controller.updateEditedResult($0) }
                    ),
                    isStreaming: false,
                    isEditing: isEditing,
                    onClickToEdit: { controller.setEditing(true) },
                    onSubmitEdit: { controller.setEditing(false) },
                    onCancelEdit: { controller.setEditing(false) }
                )
                Hairline()
                ResultToolbar(
                    action: action,
                    mode: isEditing ? .editing : .result,
                    onAccept: { controller.acceptResult() },
                    onBack: { controller.backToMenu() }
                )

            case .error(let err):
                ErrorBanner(error: err)
            }
        }
        .frame(width: 360)
        .background(Tokens.panelBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Tokens.panelBorder, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onKeyPress(.escape) {
            controller.handleEscape()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            if case .result(_, _, _, let editing) = controller.state, !editing {
                controller.acceptResult()
                return .handled
            }
            return .ignored
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.hairline)
            .frame(height: 1)
    }
}

private struct EmptySelectionHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No text selected.")
                .italic()
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textSoft)
            Text("Type a prompt to use Localpen.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textMute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
