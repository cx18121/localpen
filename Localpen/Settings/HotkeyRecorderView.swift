import SwiftUI
import KeyboardShortcuts

// Chord recorder. `KeyboardShortcuts.Recorder` is SwiftUI-native and owns
// its own persistence (keyed by the `Name`). Conflict UI is built in.
struct HotkeyRecorderView: View {
    var body: some View {
        KeyboardShortcuts.Recorder("Toggle Localpen:", name: .toggleLocalpen)
    }
}
