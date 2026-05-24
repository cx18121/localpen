import SwiftUI

// M1 tracer bullet — minimal happy-path UI.
// Replaced in M2 by the full state-machine-driven PanelView.
struct TracerBulletView: View {
    let selection: String
    let sourceAppName: String?
    let polishStream: () -> AsyncThrowingStream<String, Error>
    let onAccept: (String) -> Void
    let onDismiss: () -> Void

    @State private var result: String = ""
    @State private var isStreaming: Bool = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.isEmpty ? "(no selection)" : selection)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                if let app = sourceAppName {
                    Text("from \(app)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            HStack {
                Button("Polish") {
                    Task { await stream() }
                }
                .disabled(isStreaming || selection.isEmpty)
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button("Dismiss") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if !result.isEmpty {
                Divider()
                ScrollView {
                    Text(result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)

                HStack {
                    Spacer()
                    Button("Accept ⌘↩") { onAccept(result) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(isStreaming)
                }
            }

            if let err = errorText {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func stream() async {
        result = ""
        errorText = nil
        isStreaming = true
        defer { isStreaming = false }

        do {
            for try await token in polishStream() {
                result += token
            }
        } catch {
            errorText = "Stream error: \(error.localizedDescription)"
        }
    }
}
