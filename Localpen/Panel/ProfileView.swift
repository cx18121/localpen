import SwiftUI

struct ProfileView: View {
    @Bindable var controller: PanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar
            if controller.profileEligibleCount < MemoryService.coldStartGate
               && controller.profileDraft.voiceCard == nil {
                coldStart
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backBar: some View {
        Button { controller.dismissProfile() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("Recent").font(Typography.menuRow)
            }
            .foregroundStyle(Tokens.textSoft)
            .padding(.horizontal, Spacing.s6)
            .padding(.top, Spacing.s5)
            .padding(.bottom, Spacing.s3)
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Voice")
            voiceCardEditor

            sectionLabel("Facts", trailing: "editable")
            factsEditor

            footer
        }
    }

    private func sectionLabel(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: Spacing.s3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Tokens.textMute)
            if let trailing {
                Text("· \(trailing)")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.top, Spacing.s5)
        .padding(.bottom, Spacing.s2)
    }

    private var voiceCardEditor: some View {
        TextEditor(text: Binding(
            get: { controller.profileDraft.voiceCard ?? "" },
            set: { controller.profileDraft.voiceCard = $0.isEmpty ? nil : $0 }
        ))
        .font(Typography.menuRow)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 90, maxHeight: 160)
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                .fill(Tokens.chromeTint)
                .overlay(
                    RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                        .stroke(Tokens.hairline, lineWidth: 0.75)
                )
        )
        .padding(.horizontal, Spacing.s6)
        .onChange(of: controller.profileDraft.voiceCard) { _, _ in controller.saveProfileEdits() }
    }

    private var factsEditor: some View {
        VStack(spacing: 2) {
            ForEach(controller.profileDraft.facts.indices, id: \.self) { i in
                HStack(spacing: Spacing.s4) {
                    Circle().fill(Tokens.accent).opacity(0.75).frame(width: 5, height: 5)
                    TextField("", text: Binding(
                        get: { controller.profileDraft.facts[i] },
                        set: { controller.profileDraft.facts[i] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(Typography.menuRow)
                    .foregroundStyle(Tokens.text)
                    Spacer()
                    Button {
                        controller.profileDraft.facts.remove(at: i)
                        controller.saveProfileEdits()
                    } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Tokens.textFaint) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.s5)
                .padding(.vertical, Spacing.s3)
                .background(RoundedRectangle(cornerRadius: Spacing.innerRadius, style: .continuous)
                    .fill(Tokens.rowHighlight.opacity(0.0001)))   // tappable
            }
            Button {
                controller.profileDraft.facts.append("")
                controller.saveProfileEdits()
            } label: {
                Text("+ add a fact").font(Typography.menuRow).foregroundStyle(Tokens.textFaint)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.s5)
            .padding(.vertical, Spacing.s3)
        }
        .padding(.horizontal, Spacing.s6)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Regenerate") { controller.regenerateProfileNow() }
                .buttonStyle(.plain)
                .font(Typography.menuRow)
                .padding(.horizontal, Spacing.s5).padding(.vertical, Spacing.s3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Tokens.hairline, lineWidth: 0.75))
            Button("Forget everything") { controller.forgetMemoryEverything() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.accentError)
                .font(Typography.menuRow)
                .padding(.horizontal, Spacing.s5).padding(.vertical, Spacing.s3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Tokens.hairline, lineWidth: 0.75))
        }
        .padding(Spacing.s5)
        .background(Tokens.chromeTint)
    }

    private var coldStart: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text("Localpen is still getting to know how you write.")
                .font(Typography.result)
                .foregroundStyle(Tokens.textSoft)
            Text("Your voice profile turns on after \(MemoryService.coldStartGate) edits. So far: \(controller.profileEligibleCount) / \(MemoryService.coldStartGate).")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textFaint)
            ProgressView(value: min(1.0, Double(controller.profileEligibleCount) / Double(MemoryService.coldStartGate)))
                .progressViewStyle(.linear)
                .tint(Tokens.accent)
        }
        .padding(.horizontal, Spacing.s7)
        .padding(.vertical, Spacing.s5)
    }
}
