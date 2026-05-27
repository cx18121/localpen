import SwiftUI

/// The live multi-turn refinement surface (.conversing). Renders the pinned
/// original-selection context, a scrolling thread of paired bubbles (assistant
/// leading / user trailing, with the seed action as a quiet chip), per-turn
/// accept, inline turn error + retry, refinement chips after the latest
/// assistant reply, and a reply box pinned at the bottom. Mirrors the rail-field
/// input treatment of CustomPromptView.
struct ConversationView: View {
    @Bindable var controller: PanelController
    let conversation: Conversation

    @State private var replyText: String = ""

    /// The chip row shows only when the latest turn is an assistant reply that
    /// isn't streaming and didn't error — i.e. there is something to refine.
    private var showChips: Bool {
        conversation.turnError == nil
            && conversation.streamingText.isEmpty
            && conversation.turns.last?.role == .assistant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SelectionBlock(selection: conversation.originalSelection)
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    ForEach(conversation.turns) { turn in
                        TurnBubble(turn: turn, onAccept: { controller.acceptTurn(turn) })
                    }

                    if !conversation.streamingText.isEmpty {
                        // Live reply renders as an assistant bubble with no accept
                        // affordance until the stream finishes.
                        TurnBubble(
                            turn: ConversationTurn(role: .assistant, text: conversation.streamingText),
                            onAccept: nil
                        )
                    }

                    if let err = conversation.turnError {
                        TurnErrorRow(message: err.displayMessage) {
                            controller.retryConversationTurn()
                        }
                    }

                    if showChips {
                        ChipRow { controller.tapChip($0) }
                    }
                }
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            Hairline()

            ReplyBox(text: $replyText) { raw in
                controller.sendFollowUp(raw)
                replyText = ""
            }
        }
    }
}

// MARK: - Turn bubble

/// One thread bubble. Three shapes per the paired-bubble treatment:
/// - seed action (first user turn, `action != nil`): a quiet trailing capsule chip.
/// - assistant: leading panelBG2 bubble with a small bottom-leading corner; a
///   quiet "Use" affordance underneath calls `onAccept`.
/// - free-form user follow-up: trailing accentTint bubble with a small
///   bottom-trailing corner.
private struct TurnBubble: View {
    let turn: ConversationTurn
    let onAccept: (() -> Void)?

    private var isSeedChip: Bool { turn.role == .user && turn.action != nil }

    var body: some View {
        if isSeedChip {
            seedChip
        } else if turn.role == .assistant {
            assistantBubble
        } else {
            userBubble
        }
    }

    private var seedChip: some View {
        HStack {
            Spacer(minLength: 0)
            Text(turn.action?.pillLabel ?? turn.text)
                .font(Typography.pill)
                .foregroundStyle(Tokens.textMute)
                .padding(.horizontal, Spacing.s4)
                .padding(.vertical, Spacing.s2)
                .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 1))
        }
    }

    private var assistantBubble: some View {
        // Cap the bubble at ~86% of the panel width (400pt) so assistant replies
        // don't run edge-to-edge.
        let maxBubbleWidth = PanelController.panelSize.width * 0.86
        return HStack {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                Text(turn.text)
                    .font(Typography.result)
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .background(Tokens.panelBG2)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 4,
                            bottomTrailingRadius: 14, topTrailingRadius: 14
                        )
                    )

                if let onAccept {
                    Button(action: onAccept) {
                        Text("Use")
                            .font(Typography.footerHint)
                            .foregroundStyle(Tokens.textFaint)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 0)
            Text(turn.text)
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(Tokens.accentTint)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4, topTrailingRadius: 14
                    )
                )
        }
    }
}

// MARK: - Inline error + retry

private struct TurnErrorRow: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s4) {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Tokens.accentError)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .font(Typography.body)
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Refinement chips

/// A horizontal row of preset refinement instructions. Each chip is a quiet
/// capsule; tapping sends its label as a follow-up.
private struct ChipRow: View {
    let onTap: (String) -> Void

    private let chips = ["Soften", "Tighten", "More formal", "More casual"]

    var body: some View {
        HStack(spacing: Spacing.s3) {
            ForEach(chips, id: \.self) { label in
                Button { onTap(label) } label: {
                    Text(label)
                        .font(Typography.pill)
                        .foregroundStyle(Tokens.textSoft)
                        .padding(.horizontal, Spacing.s4)
                        .padding(.vertical, Spacing.s2)
                        .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reply box

/// The bottom reply field. Mirrors CustomPromptView's rail-field treatment: a
/// borderless GrowingTextEditor with a left rail (hairline at rest, accent when
/// focused), Return submits / ⇧Return newline, and a keyboard-hint footer.
private struct ReplyBox: View {
    @Binding var text: String
    let onSubmit: (String) -> Void

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("reply to keep refining…")
                        .foregroundStyle(Tokens.textFaint)
                        .font(Typography.menuRow)
                        .padding(.top, GrowingTextEditor.topInset)
                        .allowsHitTesting(false)
                }
                GrowingTextEditor(
                    text: $text,
                    isFocused: $isFocused,
                    autoFocus: true,
                    fontSize: 14,
                    onSubmit: { raw in onSubmit(raw) }
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 22)
            }
            .padding(.leading, Spacing.s5)
            .padding(.vertical, Spacing.s4)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? Tokens.accent : Tokens.hairline)
                    .frame(width: isFocused ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .padding(.horizontal, Spacing.s7)

            Hairline()

            HStack(spacing: Spacing.s5) {
                KbdHint("↩", "send")
                KbdHint("⇧↩", "newline")
                KbdHint("esc", "close")
            }
            .padding(.horizontal, Spacing.s6)
            .padding(.vertical, Spacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.chromeTint)
        }
    }
}
