import Foundation

// Chord + UserDefaults bridge. M1 hardcodes ⌃⌥Space; this gets used in M4.
struct HotkeyConfig {
    var keyCode: UInt
    var modifierFlags: UInt
}
