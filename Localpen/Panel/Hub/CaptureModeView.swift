import SwiftUI

/// Capture mode: a quick compose field that writes free text into the vault's
/// `raw/inbox/` (ADR 0015 additive write) for later triage via `/cxkb-inbox`.
struct CaptureModeView: View {
    @Bindable var controller: PanelController
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Card {
                TextEditor(text: $text)
                    .font(Typography.body)
                    .frame(minHeight: 90, maxHeight: 200)
                    .scrollContentBackground(.hidden)
            }
            HStack(spacing: Spacing.s4) {
                if let status = controller.hubCaptureStatus {
                    Text(status)
                        .font(Typography.subhead)
                        .foregroundStyle(Tokens.textMute)
                }
                Spacer()
                OutlineButton(title: "Capture to inbox") {
                    controller.commitCapture(text)
                    text = ""
                }
            }
        }
        .padding(Spacing.s5)
    }
}
