import SwiftUI

struct ProfileView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar
            if controller.profile.eligibleCount < MemoryService.coldStartGate
               && controller.profile.draft.voiceCard == nil {
                coldStart
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Back-navigation to the recents list. Inlined here (the only caller) rather than a
    /// shared component — there's no second back-nav surface to share with yet.
    private var backBar: some View {
        Button { controller.dismissProfile() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Recent")
                    .font(Typography.menuRow)
            }
            .foregroundStyle(Tokens.textSoft)
            .padding(.horizontal, Spacing.s6)
            .padding(.top, Spacing.s5)
            .padding(.bottom, Spacing.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Voice")
            voiceCardEditor

            SectionHeader(title: "Facts", trailing: "editable")
            factsEditor

            footer
        }
    }

    private var voiceCardEditor: some View {
        Card {
            TextEditor(text: Binding(
                get: { controller.profile.draft.voiceCard ?? "" },
                set: { controller.profile.draft.voiceCard = $0.isEmpty ? nil : $0 }
            ))
            .font(Typography.menuRow)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 90, maxHeight: 160)
        }
        .padding(.horizontal, Spacing.s6)
        .onChange(of: controller.profile.draft.voiceCard) { _, _ in controller.profile.saveEdits() }
    }

    private var factsEditor: some View {
        VStack(spacing: 0) {
            ForEach(controller.profile.draft.facts.indices, id: \.self) { i in
                factRow(at: i)
            }
            Button {
                controller.profile.draft.facts.append("")
                controller.profile.saveEdits()
            } label: {
                HStack(spacing: Spacing.s4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.textFaint)
                        .frame(width: 18)
                    Text("Add a fact")
                        .font(Typography.menuRow)
                        .foregroundStyle(Tokens.textFaint)
                    Spacer()
                }
                .padding(.horizontal, Spacing.s5)
                .padding(.vertical, Spacing.s3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s6)
        .padding(.bottom, Spacing.s4)
    }

    private func factRow(at index: Int) -> some View {
        // Codex fix: editing an existing fact must persist on change — the
        // previous binding only persisted on add/remove, silently losing edits.
        FactRow(
            text: Binding(
                get: { controller.profile.draft.facts[index] },
                set: { controller.profile.draft.facts[index] = $0 }
            ),
            onCommit: { controller.profile.saveEdits() },
            onDelete: {
                controller.profile.draft.facts.remove(at: index)
                controller.profile.saveEdits()
            }
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            OutlineButton(title: "Regenerate") { controller.profile.regenerateNow() }
            OutlineButton(title: "Forget everything", role: .destructive) {
                controller.profile.forgetEverything()
            }
        }
        .padding(Spacing.s5)
        .background(Tokens.chromeTint)
    }

    private var coldStart: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text("Localpen is still getting to know how you write.")
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.textSoft)
            Text("Your voice profile turns on after \(MemoryService.coldStartGate) edits. So far: \(controller.profile.eligibleCount) / \(MemoryService.coldStartGate).")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
            ProgressView(value: min(1.0, Double(controller.profile.eligibleCount) / Double(MemoryService.coldStartGate)))
                .progressViewStyle(.linear)
                .tint(Tokens.accent)
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.vertical, Spacing.s5)
    }
}

/// One editable fact bullet — text field with hover-reveal delete. Persists
/// every text change through `onCommit` (was previously UI-only — see Codex
/// review).
private struct FactRow: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: Spacing.s4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(Tokens.accent.opacity(0.7))
                .frame(width: 18)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Typography.menuRow)
                .foregroundStyle(Tokens.text)
                .onChange(of: text) { _, _ in onCommit() }
            Spacer()
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tokens.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.s5)
        .padding(.vertical, Spacing.s3)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.rowHighlight)
                .opacity(hover ? 0.5 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
