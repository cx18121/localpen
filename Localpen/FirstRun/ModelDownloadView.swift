import SwiftUI

struct ModelDownloadView: View {
    let bytesDone: Int64
    let bytesTotal: Int64
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var didStart: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Downloading Qwen 2.5 7B Instruct")
                .font(Typography.headline)
                .foregroundStyle(Tokens.text)

            Text("This happens once. Your model lives on your Mac after this.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.panelBG2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.accent)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 4)

            Text(progressText)
                .font(Typography.body.monospacedDigit())
                .foregroundStyle(Tokens.textSoft)

            Text("Localpen saves your interactions locally so it can learn your style over time. Your data never leaves this Mac.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                if !didStart {
                    Button(action: { didStart = true; onStart() }) {
                        Text("Download")
                            .padding(.horizontal, Spacing.s7)
                            .padding(.vertical, Spacing.s3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accent)
                } else {
                    Button(action: { didStart = false; onCancel() }) {
                        Text("Cancel")
                            .padding(.horizontal, Spacing.s5)
                            .padding(.vertical, Spacing.s3)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(Spacing.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Auto-start if user is on this screen (skip if already started or in progress).
            if !didStart && bytesDone == 0 {
                didStart = true
                onStart()
            }
        }
    }

    private var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    private var progressText: String {
        let doneGB = Double(bytesDone) / 1_073_741_824
        let totalGB = Double(bytesTotal) / 1_073_741_824
        if bytesTotal <= 0 {
            return String(format: "%.2f GB", doneGB)
        }
        return String(format: "%.2f GB of %.2f GB", doneGB, totalGB)
    }
}
