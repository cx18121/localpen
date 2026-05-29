import SwiftUI

struct ModelPickerView: View {
    let registry: ModelRegistry
    let switchModel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Installed models")
                .font(Typography.body)
                .foregroundStyle(Tokens.text)

            ForEach(registry.models, id: \.id) { model in
                row(for: model)
            }

            Spacer()

            Text("Select a downloaded model to make it active — Localpen reloads the local server on the new model. To add a custom model, edit ~/Library/Application Support/Localpen/models.toml and restart.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(for model: ModelDescriptor) -> some View {
        let isActive = model.id == registry.activeModelID
        let installed = isInstalled(model)
        // Only installed, non-active models are selectable: switching to a
        // not-downloaded model would fail the server's file-not-found guard.
        let isSelectable = installed && !isActive

        return Button {
            switchModel(model.id)
        } label: {
            HStack(spacing: Spacing.s5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(Typography.body)
                        .foregroundStyle(Tokens.text)
                    Text("\(model.id) · \(String(format: "%.1f GB", Double(model.downloadSizeBytes) / 1_073_741_824))")
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.textMute)
                }
                Spacer()
                Text(installed ? "Installed" : "Not downloaded")
                    .font(Typography.subhead)
                    .foregroundStyle(installed ? Tokens.accent : Tokens.textMute)
                if isActive {
                    Text("Active")
                        .font(Typography.pill)
                        .foregroundStyle(Tokens.accent)
                        .padding(.horizontal, Spacing.s3)
                        .padding(.vertical, 2)
                        .background(Tokens.accentTint)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, Spacing.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }

    private func isInstalled(_ model: ModelDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: registry.modelPath(for: model).path)
    }
}
