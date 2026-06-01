import SwiftUI

/// People mode: browse the people graph (pages of type `.person`). Empty until real
/// person pages are filed — `people/` ships as scaffolding (ADR 0015/0016).
struct PeopleModeView: View {
    @Bindable var controller: PanelController

    var body: some View {
        if controller.hubPeople.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: "No people yet",
                caption: "People pages (Compiled Truth + Timeline) show here as they're added to people/."
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    SectionHeader(title: "People", trailing: "\(controller.hubPeople.count)")
                    ForEach(controller.hubPeople, id: \.path) { person in
                        MenuRow(icon: "person.crop.circle", title: person.title, trailing: .chevron) {
                            controller.openNote(person)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }
}
