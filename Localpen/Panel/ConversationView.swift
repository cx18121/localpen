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
    /// Suppressed for ask threads: the chips are writing-transform follow-ups
    /// (Soften/Tighten/…), nonsensical for a free-form Q&A answer.
    private var showChips: Bool {
        conversation.turnError == nil
            && conversation.streamingText.isEmpty
            && conversation.turns.last?.role == .assistant
            && !conversation.isAsk
    }

    /// Which accept affordances each finished assistant bubble shows. Replace
    /// pastes back into the source app; Copy writes to the clipboard. Ask
    /// threads always offer Copy (an answer is information you may want to
    /// keep), so ask-with-selection offers BOTH — you decide whether the
    /// answer overwrites your selection. See `AcceptAffordances.resolve`.
    private var affordances: (replace: Bool, copy: Bool) {
        AcceptAffordances.resolve(pastesBack: controller.pastesBackOnAccept,
                                  isAsk: conversation.isAsk)
    }

    /// The pinned context above the thread. Writing threads show the original
    /// selection being transformed. Ask threads show the *attached* selection
    /// (the real context) when one survived submit — never the question, which
    /// already reads as the seed user bubble. Ask-without-selection shows nothing.
    @ViewBuilder
    private var contextBlock: some View {
        if conversation.isAsk {
            if let sel = conversation.seedAskContext?.selection,
               !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SelectionBlock(selection: Selection(
                    text: sel,
                    sourceBundleID: nil,
                    sourceAppName: conversation.seedAskContext?.appLabel
                ))
                Hairline()
            }
            // The calendar context the answer was grounded in (ADR 0012). Pinned
            // so a resumed thread shows the schedule the model actually saw — it's
            // a point-in-time snapshot, not live.
            if let cal = conversation.seedAskContext?.calendar,
               !cal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: Spacing.s2) {
                    Image(systemName: "calendar")
                        .font(Typography.selectionMeta)
                        .foregroundStyle(Tokens.textMute)
                    Text(cal)
                        .font(Typography.selectionMeta)
                        .foregroundStyle(Tokens.textMute)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s4)
                Hairline()
            }
        } else {
            SelectionBlock(selection: conversation.originalSelection)
            Hairline()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always-available recents control: mid-conversation you can still jump
            // to history (the menu states have their own in PanelFooter).
            HStack {
                Spacer()
                Button { controller.openHistory() } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textFaint)
                }
                .buttonStyle(.plain)
                .help("Recent conversations")
            }
            .padding(.horizontal, Spacing.s6)
            .padding(.top, Spacing.s3)

            contextBlock

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    ForEach(conversation.turns) { turn in
                        TurnBubble(
                            turn: turn,
                            onReplace: affordances.replace ? { controller.acceptTurn(turn) } : nil,
                            onCopy: affordances.copy ? { controller.copyTurn(turn) } : nil
                        )
                    }

                    if !conversation.streamingText.isEmpty {
                        // Live reply renders as an assistant bubble with no accept
                        // affordance until the stream finishes.
                        TurnBubble(
                            turn: ConversationTurn(role: .assistant, text: conversation.streamingText),
                            onReplace: nil,
                            onCopy: nil
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
            // Cap the scrollable thread so SelectionBlock + ReplyBox stay visible
            // within the fixed 480pt panel (PanelController.panelSize.height).
            .frame(maxHeight: 280)

            Hairline()

            ReplyBox(text: $replyText, autoFocus: true,
                     placeholder: conversation.isAsk ? "Ask a follow-up…" : "reply to keep refining…") { raw in
                controller.sendFollowUp(raw)
                replyText = ""
            }
            // While a turn streams, submission is gated in the controller; dim and
            // disable the field so that's visible rather than a silent no-op.
            .disabled(conversation.isStreaming)
            .opacity(conversation.isStreaming ? 0.5 : 1)
        }
    }
}

// MARK: - Accept affordance policy

/// Pure decision for which accept affordances a finished assistant bubble
/// offers, extracted so the rule is unit-testable without rendering a view.
///
/// - `replace`: paste the reply back over the source app's selection. Only
///   when the live session can paste back (writing transforms, and
///   ask-with-selection).
/// - `copy`: write the reply to the clipboard. Whenever paste-back is
///   unavailable (create-class, resumed threads), AND additionally on every
///   ask thread — an answer is information you may want to keep rather than
///   stamp over your selection. So ask-with-selection offers BOTH.
enum AcceptAffordances {
    static func resolve(pastesBack: Bool, isAsk: Bool) -> (replace: Bool, copy: Bool) {
        (replace: pastesBack, copy: !pastesBack || isAsk)
    }
}

// MARK: - Turn bubble

/// One thread bubble. Two shapes:
/// - assistant: leading panelBG2 bubble with a small bottom-leading corner; a
///   tiny `↩ Replace` / `↩ Copy` meta-line underneath. Either, both, or neither
///   may show, per `AcceptAffordances`.
/// - user (seed action AND free-form follow-ups): trailing bubble. The seed
///   turn carries an `action`; we use `action.seedSentence` so it reads as a
///   real first message ("Proofread this", "Make this more formal") instead
///   of a cryptic "Proofread" tag.
private struct TurnBubble: View {
    let turn: ConversationTurn
    let onReplace: (() -> Void)?
    let onCopy: (() -> Void)?

    /// Display text for a user turn — the seed action's conversational sentence
    /// when present, otherwise the typed follow-up.
    private var userDisplayText: String {
        if let action = turn.action { return action.seedSentence }
        return turn.text
    }

    var body: some View {
        if turn.role == .assistant {
            assistantBubble
        } else {
            userBubble
        }
    }

    private var assistantBubble: some View {
        // Cap the bubble at ~86% of the panel width (400pt) so assistant replies
        // don't run edge-to-edge. fixed-width panel; switch to GeometryReader if the panel ever resizes.
        let maxBubbleWidth = PanelController.panelSize.width * 0.86
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(turn.text)
                    .font(Typography.result)
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Spacing.bubbleInsetV)
                    .padding(.horizontal, Spacing.bubbleInsetH)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    .background(Tokens.panelBG2)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 4,
                            bottomTrailingRadius: 14, topTrailingRadius: 14
                        )
                    )

                if onReplace != nil || onCopy != nil {
                    HStack(spacing: Spacing.s4) {
                        if let onReplace {
                            AcceptAffordanceButton(
                                label: "Replace",
                                help: "Replace the original selection in the source app with this reply",
                                onTap: onReplace
                            )
                        }
                        if let onCopy {
                            AcceptAffordanceButton(
                                label: "Copy",
                                help: "Copy this reply to the clipboard",
                                onTap: onCopy
                            )
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 0)
            Text(userDisplayText)
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Spacing.bubbleInsetV)
                .padding(.horizontal, Spacing.bubbleInsetH)
                .background(Tokens.text.opacity(0.10))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4, topTrailingRadius: 14
                    )
                )
        }
    }
}

/// A tiny meta-line under an assistant bubble that reads as metadata more than
/// a CTA — return glyph + verb in faint text, lifting to soft on hover so it's
/// discoverable without ever feeling loud. Owns its own hover state so two can
/// sit side by side (Replace + Copy) without sharing a highlight.
private struct AcceptAffordanceButton: View {
    let label: String
    let help: String
    let onTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .medium))
                Text(label)
                    .font(Typography.footerHint)
            }
            .foregroundStyle(hover ? Tokens.textSoft : Tokens.textFaint)
            .padding(.leading, Spacing.bubbleInsetH - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
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

// ReplyBox now lives in ReplyBox.swift (shared with the one-shot result view).
