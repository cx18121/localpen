import SwiftUI
import KeyboardShortcuts

// Chord recorder. KeyboardShortcuts ships a SwiftUI-native Recorder.
// Real Settings wiring lands in M4.
struct HotkeyRecorderView: View {
    var body: some View {
        KeyboardShortcuts.Recorder("Toggle Localpen:", name: .toggleLocalpen)
    }
}
