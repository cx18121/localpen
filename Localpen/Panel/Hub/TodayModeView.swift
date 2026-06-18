import SwiftUI

/// Today — the hub's home glance (ADR 0024). One scannable column that absorbed the former
/// Now (Focus glance), Capture (quick jot), and Suggestions (To review) modes. Each section
/// hides when empty and taps through to its fuller surface; follow-ups are a teaser into
/// People, not a duplicate of it. Read-mostly: the only write here is the quick jot.
struct TodayModeView: View {
    @Bindable var controller: PanelController
    @State private var jot = ""

    private var hub: HubModel { controller.hub }
    private var followUps: [PeopleInsights.Person] { hub.peopleInsights.followUpsDue }

    /// Follow-ups shown inline before deferring the rest to People.
    private static let followUpTeaser = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s3) {
                jotField

                if !hub.nowText.isEmpty { focusBlock }
                if !followUps.isEmpty { followUpsBlock }
                if !hub.suggestions.isEmpty { reviewBlock }
                if let schedule = hub.todaySchedule { scheduleBlock(schedule) }
                if !hub.todayInbox.isEmpty { inboxBlock }

                if isGlanceEmpty { emptyState }
            }
            .padding(.bottom, Spacing.s5)
        }
        .frame(maxHeight: controller.readingMaxHeight)
        .onAppear { hub.loadToday() }
    }

    // MARK: - Quick jot (folds Capture)

    private var jotField: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s3) {
                Image(systemName: "square.and.pencil")
                    .font(Typography.body)
                    .foregroundStyle(Tokens.textFaint)
                TextField("Jot a thought…", text: $jot)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .onSubmit {
                        hub.commitCapture(jot)
                        jot = ""
                    }
            }
            .padding(.horizontal, Spacing.s7)
            .padding(.vertical, Spacing.s4)
            if let status = hub.captureStatus {
                Text(status)
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textMute)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.bottom, Spacing.s2)
            }
            Hairline()
        }
    }

    // MARK: - Focus (folds Now)

    private var focusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            header("Focus", action: ("Open", { hub.openNow() }))
            // Render now.md as real markdown (headings, bullets, wikilinks), not raw text.
            // "Open" edits it in Obsidian; the panel re-reads on reopen.
            MarkdownText(hub.nowText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.s7)
        }
    }

    // MARK: - Follow-ups (teaser → People, no longer duplicates the full list)

    private var followUpsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Follow-ups", trailing: "\(followUps.count)")
            ForEach(followUps.prefix(Self.followUpTeaser)) { p in
                MenuRow(icon: "person.crop.circle", title: p.name,
                        trailing: .text(p.followUp ?? "")) { hub.openNote(p.page) }
            }
            MenuRow(icon: "person.2", title: "All people", trailing: .chevron) {
                hub.setMode(.people)
            }
        }
    }

    // MARK: - To review (folds Suggestions)

    private var reviewBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("To review", trailing: "\(hub.suggestions.count)")
            if let status = hub.suggestionStatus {
                Text(status)
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textMute)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.bottom, Spacing.s2)
            }
            ForEach(hub.suggestions, id: \.id) { suggestion in
                HStack(alignment: .top, spacing: Spacing.s3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.summary)
                            .font(Typography.menuRow)
                            .foregroundStyle(Tokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(suggestion.isOneClickApplicable
                             ? suggestion.kind : "\(suggestion.kind) · needs manual editing")
                            .font(Typography.subhead)
                            .foregroundStyle(Tokens.textFaint)
                    }
                    Spacer(minLength: Spacing.s2)
                    if suggestion.isOneClickApplicable {
                        OutlineButton(title: "Apply") { hub.applySuggestion(suggestion) }
                    }
                    OutlineButton(title: "Dismiss") { hub.dismissSuggestion(suggestion) }
                }
                .padding(.horizontal, Spacing.s7)
                .padding(.vertical, Spacing.s3)
            }
        }
    }

    // MARK: - Schedule + Inbox

    private func scheduleBlock(_ schedule: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            header("Schedule")
            Text(schedule)
                .font(Typography.body)
                .foregroundStyle(Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.s7)
        }
    }

    private var inboxBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Recently captured", trailing: "\(hub.todayInbox.count)")
            ForEach(hub.todayInbox) { item in
                MenuRow(icon: "tray", title: item.title, trailing: .chevron) {
                    hub.openInboxItem(item)   // open the jot in Obsidian to flesh out / file
                }
            }
        }
    }

    // MARK: - Empty + header

    /// "Empty" ignores the jot field (always present) — only the read sections.
    private var isGlanceEmpty: Bool {
        hub.nowText.isEmpty && followUps.isEmpty && hub.suggestions.isEmpty
            && hub.todaySchedule == nil && hub.todayInbox.isEmpty
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "sun.max",
            title: "Nothing to brief",
            caption: "Your focus, due follow-ups, schedule, and fresh captures gather here."
        )
    }

    /// A section header matching `SectionHeader`, with an optional tappable trailing action
    /// (e.g. Focus → "Open") that the plain `SectionHeader` can't carry.
    @ViewBuilder
    private func header(_ title: String, trailing: String? = nil,
                        action: (label: String, run: () -> Void)? = nil) -> some View {
        if let action {
            HStack(spacing: Spacing.s3) {
                Text(title.uppercased())
                    .font(Typography.sectionHeader)
                    .tracking(0.9)
                    .foregroundStyle(Tokens.textFaint)
                Spacer(minLength: 0)
                Button(action: action.run) {
                    Text(action.label)
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.s7)
            .padding(.top, Spacing.s5)
            .padding(.bottom, Spacing.s2)
        } else {
            SectionHeader(title: title, trailing: trailing)
        }
    }
}
