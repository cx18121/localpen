import SwiftUI

struct AskInput: View {
    @Bindable var controller: PanelController

    @State private var question: String = ""

    var body: some View {
        if controller.mailPickerActive {
            MailPicker(controller: controller)
        } else {
            VStack(alignment: .leading, spacing: Spacing.s3) {
                chipRail
                editorWithPlaceholder
                footer
            }
            .padding(Spacing.s5)
        }
    }

    @ViewBuilder
    private var chipRail: some View {
        let sources = controller.askContext.sources
        let selection = controller.askContext.selection
        // Attached sources (files, mail, …) share the top row as gray removable chips;
        // calendar gets its own full-width accent row (ADR 0016 §3); the selection operand
        // is its own chip. Below them, the opt-in "add context" tray (ADR 0020).
        let neutral = sources.filter { $0.kind != .calendar }
        let calendar = sources.first { $0.kind == .calendar }
        let available = controller.availableAskSources
        if !sources.isEmpty || selection != nil || !available.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                if !neutral.isEmpty || selection != nil {
                    HStack(spacing: Spacing.s2) {
                        ForEach(neutral, id: \.kind) { item in
                            // The mail chip reopens the picker on tap (edit your selection);
                            // others are display-only. The × removes either.
                            AskChip(text: item.chipText,
                                    onTap: item.kind == .mail ? { controller.openMailPicker() } : nil,
                                    onRemove: { controller.removeAskSource(item.kind) })
                        }
                        if let selection {
                            AskChip(text: Self.selectionPreview(selection),
                                    onRemove: { controller.removeAskSelectionChip() })
                        }
                        Spacer()
                    }
                }
                if let calendar {
                    CalendarChip(text: calendar.label,
                                 onRemove: { controller.removeAskSource(.calendar) })
                }
                if !available.isEmpty {
                    HStack(spacing: Spacing.s2) {
                        Text("Add context")
                            .font(Typography.subhead)
                            .foregroundStyle(Tokens.textFaint)
                        ForEach(available, id: \.self) { kind in
                            AddChip(label: Self.sourceLabel(kind)) {
                                controller.addAskSource(kind)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    /// Tray label for an addable source kind.
    private static func sourceLabel(_ kind: ContextKind) -> String {
        switch kind {
        case .calendar: "Calendar"
        case .mail:     "Mail"
        case .files:    "File"
        case .app:      "App"
        case .screen:   "Screen"
        default:        kind.rawValue.capitalized
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

/// An addable source in the opt-in "add context" tray (ADR 0020): a dimmed, outlined
/// `+ Label` button. Tapping captures that source NOW and turns it into an `AskChip`.
private struct AddChip: View {
    let label: String
    let onAdd: () -> Void
    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: Spacing.s1) {
                Image(systemName: "plus")
                    .font(Typography.microGlyph)
                Text(label)
                    .font(Typography.subhead)
            }
            .foregroundStyle(Tokens.textFaint)
            .padding(.horizontal, Spacing.s3)
            .padding(.vertical, Spacing.s1)
            .background(
                RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                    .stroke(Tokens.panelBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add \(label.lowercased()) as context for this ask")
    }
}

private struct AskChip: View {
    let text: String
    var onTap: (() -> Void)? = nil
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: Spacing.s1) {
            if let onTap {
                Button(action: onTap) { label }.buttonStyle(.plain)
            } else {
                label
            }
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

    private var label: some View {
        Text(text)
            .font(Typography.subhead)
            .foregroundStyle(Tokens.textSoft)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 190, alignment: .leading)
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
