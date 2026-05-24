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
                InputEditor(text: $controller.inputText, sourceAppName: nil)
                Hairline()
                ActionMenuView(controller: controller)
                Hairline()
                PanelFooter()

            case .captured(let sel):
                InputEditor(text: $controller.inputText, sourceAppName: sel.sourceAppName)
                Hairline()
                ActionMenuView(controller: controller)
                Hairline()
                PanelFooter()

            case .customPrompt(let sel):
                if let sel = sel {
                    SelectionBlock(selection: sel)
                    Hairline()
                }
                CustomPromptView(
                    onSubmit: { controller.submitCustomPrompt($0) }
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
                    onClickToEdit: { controller.setEditing(true) }
                )
                Hairline()
                ResultToolbar(
                    action: action,
                    mode: isEditing ? .editing : .result,
                    onAccept: { controller.acceptResult() },
                    onBack: { controller.backToMenu() }
                )

            case .error(let err, _):
                ErrorBanner(error: err, onAction: { controller.retryFromError() })
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
        .contextMenu {
            if case .result(_, _, let text, _) = controller.state {
                Button("Copy Result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            SettingsLink {
                Text("Settings…")
            }
            Button("About Localpen") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
    }

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
