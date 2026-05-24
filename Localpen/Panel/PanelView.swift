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
        .clipShape(RoundedRectangle(cornerRadius: Spacing.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.panelRadius)
                .stroke(Tokens.panelBorder, lineWidth: 1)
        )
        .animation(Motion.menuToResult, value: stateKey(controller.state))
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

    /// Drives top-level region animations — we animate on the kind-change, not on every streamed token.
    private func stateKey(_ s: PanelState) -> Int {
        switch s {
        case .hidden:        return 0
        case .empty:         return 1
        case .captured:      return 2
        case .customPrompt:  return 3
        case .generating:    return 4
        case .result(_, _, _, let editing): return editing ? 6 : 5
        case .error:         return 7
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
        VStack(alignment: .leading, spacing: Spacing.s1) {
            Text("No text selected.")
                .italic()
                .font(Typography.selection)
                .foregroundStyle(Tokens.textSoft)
            Text("Type a prompt to use Localpen.")
                .font(Typography.selectionMeta)
                .foregroundStyle(Tokens.textMute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s7)
    }
}
