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
                    InputEditor(text: $controller.inputText, sourceAppName: nil)
                    Hairline()
                    ActionMenuView(controller: controller)
                    Hairline()
                    PanelFooter()

                case .captured:
                    InputEditor(text: $controller.inputText, sourceAppName: ctx.selection?.sourceAppName)
                    Hairline()
                    ActionMenuView(controller: controller)
                    Hairline()
                    PanelFooter()

                case .customPrompt:
                    if let sel = ctx.selection {
                        SelectionBlock(selection: sel)
                        Hairline()
                    }
                    CustomPromptView(
                        onSubmit: { controller.submitCustomPrompt($0) }
                    )

                case .generating(let partial):
                    if let sel = ctx.selection {
                        SelectionBlock(selection: sel)
                        Hairline()
                    }
                    ResultView(
                        text: .constant(partial),
                        isStreaming: true,
                        isEditing: false
                    )
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
                            onAccept: { controller.acceptResult() },
                            onBack: { controller.backToMenu() }
                        )
                    }

                case .error(let err):
                    ErrorBanner(error: err, onAction: { controller.retryFromError() })
                }
            }
        }
        .frame(width: 360)
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
            if case .visible(_, .result(let text, _)) = controller.state {
                Button("Copy Result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
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
