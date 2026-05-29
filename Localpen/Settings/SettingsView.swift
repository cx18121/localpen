import SwiftUI

struct SettingsView: View {
    @Environment(ModelRegistry.self) private var registry
    let persistence: Persistence?
    let switchModel: (String) -> Void

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .padding(Spacing.s8)
                .frame(width: 480, height: 240)

            ModelPickerView(registry: registry, switchModel: switchModel)
                .tabItem { Label("Model", systemImage: "cube") }
                .padding(Spacing.s8)
                .frame(width: 480, height: 320)

            HistorySettingsView(persistence: persistence)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .padding(Spacing.s8)
                .frame(width: 480, height: 240)
        }
    }
}

private struct GeneralTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s5) {
            Text("Global hotkey")
                .font(Typography.body)
                .foregroundStyle(Tokens.text)

            HotkeyRecorderView()

            Text("Press the chord you want to use. Conflicts with other apps will be flagged.")
                .font(Typography.subhead)
                .foregroundStyle(Tokens.textMute)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
