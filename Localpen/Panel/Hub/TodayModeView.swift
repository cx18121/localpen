import SwiftUI

/// Today mode — the daily briefing (ADR 0016). A morning glance composed from signals the
/// hub already has: the cached schedule, due follow-ups (People intelligence), the current
/// now.md focus, and recent inbox items awaiting triage. Read-only; each piece links to its
/// fuller mode.
struct TodayModeView: View {
    @Bindable var controller: PanelController

    private var followUps: [PeopleInsights.Person] { controller.hub.peopleInsights.followUpsDue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let schedule = controller.hub.todaySchedule {
                    section("Schedule") {
                        Text(schedule)
                            .font(Typography.body)
                            .foregroundStyle(Tokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !followUps.isEmpty {
                    SectionHeader(title: "Follow-ups due", trailing: "\(followUps.count)")
                    ForEach(followUps) { p in
                        MenuRow(icon: "person.crop.circle", title: p.name,
                                trailing: .text(p.followUp ?? "")) { controller.hub.openNote(p.page) }
                    }
                }

                if !controller.hub.nowText.isEmpty {
                    section("Now") {
                        Text(nowExcerpt)
                            .font(Typography.body)
                            .foregroundStyle(Tokens.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !controller.hub.todayInbox.isEmpty {
                    SectionHeader(title: "Inbox", trailing: "\(controller.hub.todayInbox.count)")
                    ForEach(controller.hub.todayInbox, id: \.self) { title in
                        // Glance-only: captured items have no detail view to open, so no tap affordance.
                        MenuRow(icon: "tray", title: title)
                    }
                }

                if isEmpty {
                    EmptyStateView(
                        icon: "sun.max",
                        title: "Nothing to brief",
                        caption: "Your schedule, due follow-ups, current focus, and fresh captures will gather here."
                    )
                }
            }
            .padding(.vertical, Spacing.s2)
        }
        .frame(maxHeight: controller.readingMaxHeight)
        .onAppear { controller.hub.loadToday() }
    }

    private var isEmpty: Bool {
        controller.hub.todaySchedule == nil && followUps.isEmpty
            && controller.hub.nowText.isEmpty && controller.hub.todayInbox.isEmpty
    }

    /// First ~6 non-empty lines of now.md — enough for a glance, tap "Now" for the rest.
    private var nowExcerpt: String {
        controller.hub.nowText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .joined(separator: "\n")
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        SectionHeader(title: title)
        content()
            .padding(.horizontal, Spacing.s7)
            .padding(.bottom, Spacing.s4)
    }
}
