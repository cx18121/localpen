import SwiftUI

struct ModelPickerView: View {
    let registry: ModelRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Installed models")
                .font(Typography.body)
                .foregroundStyle(Tokens.text)

            ForEach(registry.models, id: \.id) { model in
                row(for: model)
            }

            Spacer()

            Text("To add a custom model, edit ~/Library/Application Support/Localpen/models.toml and restart.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(for model: ModelDescriptor) -> some View {
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
            Text(isInstalled(model) ? "Installed" : "Not downloaded")
                .font(Typography.subhead)
                .foregroundStyle(isInstalled(model) ? Tokens.accent : Tokens.textMute)
            if model.id == registry.activeModelID {
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
    }

    private func isInstalled(_ model: ModelDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: registry.modelPath(for: model).path)
    }
}
