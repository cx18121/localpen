import SwiftUI

struct AskInput: View {
    @Bindable var controller: PanelController

    @State private var question: String = ""
    @State private var isFocused: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            chipRail
            editorWithPlaceholder
            footer
        }
        .padding(Spacing.s5)
    }

    @ViewBuilder
    private var chipRail: some View {
        let appLabel = controller.askContext.appLabel
        let selection = controller.askContext.selection
        if appLabel != nil || selection != nil {
            HStack(spacing: Spacing.s2) {
                if let appLabel {
                    AskChip(text: appLabel, onRemove: { controller.removeAskAppChip() })
                }
                if let selection {
                    AskChip(text: Self.selectionPreview(selection),
                            onRemove: { controller.removeAskSelectionChip() })
                }
                Spacer()
            }
        }
    }

    /// ZStack-overlaid placeholder, matching the existing CustomPromptView /
    /// InputEditor pattern — GrowingTextEditor has no placeholder parameter.
    private var editorWithPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            if question.isEmpty {
                Text("Ask anything")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.textFaint)
                    .padding(.top, GrowingTextEditor.topInset)
                    .allowsHitTesting(false)
            }
            GrowingTextEditor(
                text: $question,
                isFocused: $isFocused,
                autoFocus: true,
                focusTick: 0,
                fontSize: 14,
                onSubmit: { raw in
                    controller.askSubmitted(raw)
                    question = ""
                }
            )
        }
        .frame(minHeight: 60, maxHeight: 240)
    }

    private var footer: some View {
        HStack {
            Text("⏎ to ask · ⇧⏎ newline")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
            Spacer()
        }
    }

    /// A one-line preview of the attached selection: collapse runs of
    /// whitespace/newlines to single spaces, then truncate to a readable
    /// length with an ellipsis. Shows the actual text (like an editor's
    /// attachment chip) instead of an opaque "N words selected" count.
    private static func selectionPreview(_ s: String) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limit = 40
        if collapsed.count <= limit { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private struct AskChip: View {
    let text: String
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text("◦ " + text)
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.rowHighlight)
        )
    }
}
