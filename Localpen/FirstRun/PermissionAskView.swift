import SwiftUI

struct PermissionAskView: View {
    let onOpenSettings: () -> Void
    @State private var whyExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Localpen needs Accessibility permission")
                .font(Typography.headline)
                .foregroundStyle(Tokens.text)

            Text("Localpen reads selected text and pastes results back into the app you're writing in. macOS will ask for Accessibility permission next. Your text never leaves this Mac.")
                .font(Typography.body)
                .foregroundStyle(Tokens.textSoft)
                .fixedSize(horizontal: false, vertical: true)

            FirstRunPrimaryButton(title: "Open System Settings", action: onOpenSettings)

            DisclosureGroup(isExpanded: $whyExpanded) {
                Text("Localpen uses Accessibility permission to read your text selections (via the clipboard) and paste results back. It never walks the accessibility tree, never sends anything over the network. Permission can be revoked any time in System Settings.")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.s2)
            } label: {
                Text("Why does Localpen need this?")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.accent)
            }
            .tint(Tokens.accent)

            Spacer()

            HStack {
                Text("Localpen is open source.")
                    .font(Typography.subhead)
                    .foregroundStyle(Tokens.textFaint)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.s8)
    }
}
