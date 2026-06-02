import SwiftUI

struct ModelPickerView: View {
    let registry: ModelRegistry
    let switchModel: (String) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(registry.models, id: \.id) { model in
                    row(for: model)
                }
            } header: {
                Text("Installed models")
            } footer: {
                Text("Select a downloaded model to make it active; Localpen reloads the local server on the new model. To add a custom model, edit ~/Library/Application Support/Localpen/models.toml and restart.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(for model: ModelDescriptor) -> some View {
        let isActive = model.id == registry.activeModelID
        let installed = isInstalled(model)
        // Only installed, non-active models are selectable: switching to a
        // not-downloaded model would fail the server's file-not-found guard.
        let isSelectable = installed && !isActive
        let sizeGB = String(format: "%.1f GB", Double(model.downloadSizeBytes) / 1_073_741_824)

        return Button {
            switchModel(model.id)
        } label: {
            HStack(spacing: Spacing.s4) {
                // A native-feeling selection indicator: filled check for the
                // active model, hollow circle for switchable ones.
                Image(systemName: isActive ? "checkmark.circle.fill" : (isSelectable ? "circle" : "circle.dotted"))
                    .foregroundStyle(isActive ? Tokens.accent : Tokens.textFaint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .foregroundStyle(Tokens.text)
                    Text(installed ? sizeGB : "\(sizeGB) · not downloaded")
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.textMute)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }

    private func isInstalled(_ model: ModelDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: registry.modelPath(for: model).path)
    }
}
