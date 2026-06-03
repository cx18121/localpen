import SwiftUI

/// The "+ Mail" context picker (ADR 0020 — mail is retrieval, not a recency dump).
/// Opens inside the ask surface: a search box (empty ⇒ recent inbox, last day; typed ⇒
/// sender/subject search), a list you can see and expand, and a checkbox per row to
/// attach. Confirming attaches the checked emails (full bodies) as the mail context.
struct MailPicker: View {
    @Bindable var controller: PanelController
    @State private var query: String = ""
    @State private var expanded: Set<Int64> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            searchField
            Hairline()
            list
            Hairline()
            footer
        }
        .padding(Spacing.s5)
        .onAppear {
            query = controller.mailPickerQuery
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.s2) {
            Image(systemName: "magnifyingglass")
                .font(Typography.chromeIcon)
                .foregroundStyle(Tokens.textFaint)
            TextField("Search mail, or leave empty for the last day", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(Tokens.text)
                .focused($searchFocused)
                .onChange(of: query) { _, q in controller.mailQueryChanged(q) }
                .onSubmit { controller.mailQueryChanged(query) }
        }
    }

    @ViewBuilder private var list: some View {
        let rows = displayRows
        if controller.mailPickerLoading && rows.isEmpty {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxWidth: .infinity).padding(.vertical, Spacing.s5)
        } else if rows.isEmpty {
            Text(query.isEmpty ? "No mail in the last day." : "No matches.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.s5)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row($0) }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    /// Checked emails not in the current results stay pinned on top, so a search can't
    /// hide what you've already selected.
    private var displayRows: [MailMessage] {
        let results = controller.mailPickerResults
        let resultIDs = Set(results.map(\.id))
        let pinned = controller.mailPickerSelected.values
            .filter { !resultIDs.contains($0.id) }
            .sorted { $0.date > $1.date }
        return pinned + results
    }

    private func row(_ m: MailMessage) -> some View {
        let selected = controller.isMailSelected(m.id)
        let isOpen = expanded.contains(m.id)
        return VStack(alignment: .leading, spacing: Spacing.s1) {
            HStack(spacing: Spacing.s2) {
                Button { controller.toggleMailSelection(m) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Tokens.accent : Tokens.textFaint)
                }
                .buttonStyle(.plain)

                Button {
                    if isOpen { expanded.remove(m.id) }
                    else { expanded.insert(m.id); controller.expandMailPreview(m) }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.sender)
                            .font(Typography.menuRowFocused)
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                        Text(m.subject.isEmpty ? "(no subject)" : m.subject)
                            .font(Typography.subhead)
                            .foregroundStyle(Tokens.textSoft)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(Self.relativeDate(m.date))
                    .font(Typography.selectionMeta)
                    .foregroundStyle(Tokens.textFaint)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(Typography.microGlyph)
                    .foregroundStyle(Tokens.textFaint)
            }
            .padding(.vertical, Spacing.s2)

            if isOpen {
                Text(controller.mailPickerBodies[m.id].map { $0.isEmpty ? "(no readable body)" : $0 } ?? "Loading…")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textMute)
                    .lineLimit(10)
                    .padding(.leading, 23)
                    .padding(.bottom, Spacing.s2)
            }
            Hairline()
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s3) {
            Button("Cancel") { controller.cancelMailPicker() }
                .buttonStyle(.plain)
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textSoft)
            Spacer()
            let count = controller.mailPickerSelected.count
            Button { controller.confirmMailPicker() } label: {
                Text(count == 0 ? "Done" : "Add \(count)")
                    .font(Typography.menuRowFocused)
                    .foregroundStyle(count == 0 ? Tokens.textSoft : Tokens.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static func relativeDate(_ date: Date) -> String {
        relFormatter.localizedString(for: date, relativeTo: Date())
    }
}
