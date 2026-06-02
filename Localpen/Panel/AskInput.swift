import SwiftUI

struct AskInput: View {
    @Bindable var controller: PanelController

    @State private var question: String = ""

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
        let calendar = controller.askContext.calendar
        if appLabel != nil || selection != nil || calendar != nil {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                // Neutral app/selection chips share the top row.
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
                // Calendar gets its own full-width, accent-tinted row so it reads as
                // live, distinct context — not another gray chip (ADR 0016 §3).
                if let calendar {
                    CalendarChip(text: calendar, onRemove: { controller.removeAskCalendarChip() })
                }
            }
        }
    }

    private var editorWithPlaceholder: some View {
        GrowingField(
            text: $question,
            placeholder: "Ask anything",
            autoFocus: true,
            onSubmit: { raw in
                controller.askSubmitted(raw)
                question = ""
            }
        )
        .frame(minHeight: 60, maxHeight: 240)
    }

    private var footer: some View {
        HStack(spacing: Spacing.s5) {
            KbdHint("↩", "ask")
            KbdHint("⇧↩", "newline")
            Spacer()
            // Recents access from the Ask surface — the ambient entry point
            // (hover/click) lands here, so history must be reachable without
            // first routing through the transform menu.
            Button { controller.openHistory() } label: {
                Image(systemName: "clock")
                    .font(Typography.chromeIcon)
                    .foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
            .help("Recent conversations")
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
        HStack(spacing: Spacing.s1) {
            Text(text)
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Typography.microGlyph)
                    .foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.rowHighlight)
        )
    }
}

/// The calendar context chip (ADR 0016 §3). Visually distinct from the neutral
/// `AskChip`: a `calendar` glyph in `accent`, an `accentTint` fill + `accentMute`
/// hairline, its own full-width row, and the full (untruncated, 2-line) schedule
/// text instead of a 40-char crop — so "live schedule" reads at a glance. Reuses
/// the existing accent tokens (no new hue), honoring single-accent discipline.
private struct CalendarChip: View {
    let text: String
    let onRemove: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s2) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.accent)
                .padding(.top, 1)
            Text(text)
                .font(Typography.subhead)
                .foregroundStyle(Tokens.text)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(Typography.microGlyph)
                    .foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
        }
        .padding(.horizontal, Spacing.s3)
        .padding(.vertical, Spacing.s2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.accentTint)
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                        .stroke(Tokens.accentMute, lineWidth: 0.75)
                )
        )
    }
}
