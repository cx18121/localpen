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
                    ResultPhaseView(
                        controller: controller,
                        action: ctx.action,
                        finalText: finalText,
                        isEditing: isEditing
                    )

                case .conversing:
                    if let convo = controller.conversation {
                        ConversationView(controller: controller, conversation: convo)
                    }

                case .history:
                    ThreadListView(controller: controller)

                case .profile:
                    ProfileView(controller: controller)

                case .error(let err):
                    ErrorBanner(error: err, onAction: { controller.retryFromError() })
                }
            }
        }
        .frame(width: PanelController.panelSize.width)
        .background(PanelSurface())
        .clipShape(RoundedRectangle(cornerRadius: Spacing.panelRadius, style: .continuous))
        .overlay(
            // A clean hairline edge with a faint top glass highlight — depth comes
            // from the material + shadow, not a heavy colored border.
            RoundedRectangle(cornerRadius: Spacing.panelRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Tokens.glassEdge, Tokens.panelBorder.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
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

/// The one-shot `.result` phase: result body, a follow-up reply box that
/// promotes the result into a conversation, and the accept/copy/edit toolbar.
///
/// The reply box is `autoFocus: false` and purely additive — when it isn't
/// focused, the panel's `.result` keyboard handling (Return = accept, ⌘C = copy,
/// Tab = edit, Esc = back) is unaffected, because GrowingTextEditor only
/// intercepts Return while it is first responder. The box is click-to-focus;
/// once the user types and submits, it promotes the result into a thread.
private struct ResultPhaseView: View {
    @Bindable var controller: PanelController
    let action: Action?
    let finalText: String
    let isEditing: Bool

    @State private var replyText: String = ""

    var body: some View {
        ResultView(
            text: Binding(
                get: { finalText },
                set: { controller.updateEditedResult($0) }
            ),
            isStreaming: false,
            isEditing: isEditing,
            onClickToEdit: { controller.setEditing(true) }
        )

        // Only offer the promote-to-conversation reply box once the result is
        // settled (not while the user is editing it inline).
        if !isEditing {
            Hairline()
            ReplyBox(text: $replyText, autoFocus: false, showHints: false) { raw in
                controller.promoteToConversation(followUp: raw)
                replyText = ""
            }
        }

        Hairline()
        if let action {
            ResultToolbar(
                action: action,
                mode: isEditing ? .editing : .result,
                justCopied: controller.justCopied,
                isCreate: action.operationClass == .create,
                onAccept: { controller.acceptResult() },
                onBack: { controller.backToMenu() }
            )
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
