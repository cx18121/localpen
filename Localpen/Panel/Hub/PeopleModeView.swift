import SwiftUI

/// People mode: relationship intelligence over the people graph (ADR 0015). Surfaces due
/// follow-ups and stale (reconnect) contacts above the full list. Empty until real person
/// pages are filed — `people/` ships as scaffolding (the Granola sync + dream cycle
/// populate it). Each row opens the person's page in Obsidian.
struct PeopleModeView: View {
    @Bindable var controller: PanelController

    private var insights: PeopleInsights.Result { controller.hub.peopleInsights }

    var body: some View {
        if insights.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: "No people yet",
                caption: "People pages (Compiled Truth + Timeline) show here as they're added to people/."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !insights.followUpsDue.isEmpty {
                        SectionHeader(title: "Follow-ups due", trailing: "\(insights.followUpsDue.count)")
                        ForEach(insights.followUpsDue) { row($0, trailing: .text($0.followUp ?? "")) }
                    }
                    if !insights.reconnect.isEmpty {
                        SectionHeader(title: "Reconnect", trailing: "\(insights.reconnect.count)")
                        ForEach(insights.reconnect) { row($0, trailing: .text(staleLabel($0))) }
                    }
                    SectionHeader(title: "All people", trailing: "\(insights.all.count)")
                    ForEach(insights.all) { row($0, trailing: .chevron) }
                }
            }
            .frame(maxHeight: controller.readingMaxHeight)
        }
    }

    private func row(_ p: PeopleInsights.Person, trailing: MenuRow.Trailing) -> some View {
        MenuRow(icon: "person.crop.circle", title: p.name, trailing: trailing) {
            controller.hub.openNote(p.page)
        }
    }

    private func staleLabel(_ p: PeopleInsights.Person) -> String {
        guard let d = p.daysSinceContact else { return "" }
        return "\(d)d"
    }
}
