import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // ⌃⌥Space hardcoded default for M1. User can rebind in M4 Settings.
    static let toggleLocalpen = Self(
        "toggleLocalpen",
        default: .init(.space, modifiers: [.control, .option])
    )
}

@MainActor
final class HotkeyService {
    var onFire: (() -> Void)?

    func install() {
        KeyboardShortcuts.onKeyDown(for: .toggleLocalpen) { [weak self] in
            self?.onFire?()
        }
    }

    func uninstall() {
        KeyboardShortcuts.disable(.toggleLocalpen)
    }
}
