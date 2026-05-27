import SwiftUI
import AppKit

struct PanelView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.state {
            case .hidden:
                EmptyView()

            case .visible(let ctx, let phase):
                switch phase {
                case .empty:
                    InputEditor(text: $controller.inputText, sourceAppName: nil, autoFocus: true, focusTick: controller.inputFocusTick)
                    Hairline()
                    ActionMenuView(controller: controller)
                    Hairline()
                    PanelFooter(onHistory: { controller.openHistory() })

                case .captured:
                    InputEditor(text: $controller.inputText, sourceAppName: ctx.selection?.sourceAppName, focusTick: controller.inputFocusTick)
                    Hairline()
                    ActionMenuView(controller: controller)
                    Hairline()
                    PanelFooter(onHistory: { controller.openHistory() })

                case .customPrompt:
                    if let sel = ctx.selection {
                        SelectionBlock(selection: sel)
                        Hairline()
                    }
                    CustomPromptView(
                        action: ctx.action ?? .custom(""),
                        onSubmit: { controller.submitCompose($0) }
                    )

                case .generating:
                    if let sel = ctx.selection {
                        SelectionBlock(selection: sel)
                        Hairline()
                    }
                    StreamingResultView(controller: controller)
                    Hairline()
                    if let action = ctx.action {
                        ResultToolbar(action: action, mode: .streaming)
                    }

                case .result(let finalText, let isEditing):
                    if let sel = ctx.selection {
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
                    if let action = ctx.action {
                        ResultToolbar(
                            action: action,
                            mode: isEditing ? .editing : .result,
                            justCopied: controller.justCopied,
                            isCreate: action.operationClass == .create,
                            onAccept: { controller.acceptResult() },
                            onBack: { controller.backToMenu() }
                        )
                    }

                case .conversing:
                    if let convo = controller.conversation {
                        ConversationView(controller: controller, conversation: convo)
                    }

                case .history:
                    ThreadListView(controller: controller)

                case .error(let err):
                    ErrorBanner(error: err, onAction: { controller.retryFromError() })
                }
            }
        }
        .frame(width: PanelController.panelSize.width)
        .background(PanelSurface())
        .clipShape(RoundedRectangle(cornerRadius: Spacing.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Spacing.panelRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [Tokens.glassEdge, Tokens.panelBorder],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .animation(Motion.menuToResult, value: controller.state.renderKey)
        .contextMenu {
            if case .visible(_, .result) = controller.state {
                Button("Copy Result") { controller.copyResult() }
            }
            Button("Settings…") { controller.openSettings() }
            Button("About Localpen") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
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

/// Isolates per-token re-renders to just the streaming text. Because this view
/// (not PanelView) reads `controller.streamingText`, a new token invalidates
/// only this subtree while the surrounding panel stays put.
struct StreamingResultView: View {
    @Bindable var controller: PanelController

    var body: some View {
        ResultView(
            text: .constant(controller.streamingText),
            isStreaming: true,
            isEditing: false
        )
    }
}
