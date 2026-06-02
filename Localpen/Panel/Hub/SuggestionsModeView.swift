import SwiftUI

/// Suggestions mode (ADR 0015): the queue of high-judgment curation proposals the dream
/// cycle would NOT auto-apply. Each row shows the proposal; Apply writes it (the one click
/// is the human judgment the gate required), Dismiss drops it. Proposals that need genuine
/// manual editing (contradictions, identity merges) show no Apply — just a hint + Dismiss.
struct SuggestionsModeView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = controller.hubSuggestionStatus {
                Text(status)
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textMute)
                    .padding(.horizontal, Spacing.s7)
                    .padding(.vertical, Spacing.s3)
                Hairline()
            }

            if controller.hubSuggestions.isEmpty {
                EmptyStateView(
                    icon: "lightbulb",
                    title: "No suggestions",
                    caption: "The nightly curation pass proposes high-judgment changes here for your review."
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        SectionHeader(title: "Proposed", trailing: "\(controller.hubSuggestions.count)")
                        ForEach(controller.hubSuggestions, id: \.id) { row($0) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .onAppear { controller.loadSuggestions() }
    }

    private func row(_ suggestion: Suggestion) -> some View {
        HStack(alignment: .top, spacing: Spacing.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.summary)
                    .font(Typography.menuRow)
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(suggestion.isOneClickApplicable ? suggestion.kind : "\(suggestion.kind) · needs manual editing")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
            }
            Spacer(minLength: Spacing.s2)
            if suggestion.isOneClickApplicable {
                Button("Apply") { controller.applySuggestion(suggestion) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.accent)
                    .font(Typography.menuRowFocused)
            }
            Button("Dismiss") { controller.dismissSuggestion(suggestion) }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textMute)
                .font(Typography.subhead)
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.vertical, Spacing.s3)
    }
}
