import SwiftUI

struct FirstRunView: View {
    @Bindable var coordinator: FirstRunCoordinator

    var body: some View {
        ZStack {
            Tokens.panelBG.ignoresSafeArea()
            switch coordinator.step {
            case .permission:
                PermissionAskView(onOpenSettings: { coordinator.openSystemSettings() })
            case .downloading(let done, let total):
                ModelDownloadView(
                    bytesDone: done,
                    bytesTotal: total,
                    onStart: { Task { await coordinator.startDownload() } },
                    onCancel: { coordinator.cancelDownload() }
                )
            case .downloadError(let message):
                DownloadErrorView(message: message, onRetry: { Task { await coordinator.startDownload() } })
            case .ready:
                Color.clear
            }
        }
        .frame(width: 480, height: 320)
    }
}

private struct DownloadErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s5) {
            Text("Download failed")
                .font(Typography.headline)
                .foregroundStyle(Tokens.text)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Tokens.accentError)
                .multilineTextAlignment(.center)
            FirstRunPrimaryButton(title: "Retry", action: onRetry)
        }
        .padding(Spacing.s8)
    }
}
