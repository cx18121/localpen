import AppKit

extension NSScreen {
    /// The built-in notched display, if any. DynamicNotchKit's own `hasNotch` is
    /// internal to the package, so we detect the notch via the safe-area top inset
    /// (non-zero only on built-in notched displays). Falls back to the main screen,
    /// then the first — so the notch surface never lands on an external monitor when
    /// a notched built-in display is present (the source app + capture happen on
    /// whatever display the user works on, but the surface itself stays at the notch).
    static func notched() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
    }
}
