import Foundation

/// Screen-context configuration (ADR 0021): the user's opt-in toggle for OCR'ing the
/// window they summoned from. Like Mail, it needs a TCC grant — **Screen Recording** —
/// which (verified in a spike) Localpen CAN obtain, since it's a manual System-Settings
/// grant, not the prompt+entitlement that EventKit/Calendar fails on. A missing grant
/// degrades to "no chip" (the capture returns nil).
enum ScreenAccess {
    private static let enabledKey = "screenContextEnabled"

    /// The user's Settings toggle. Default false — off until enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hot-path gate. Just the toggle; the Screen Recording grant is checked at capture.
    static var isActive: Bool { isEnabled }

    /// Cap for the OCR'd text. A dense window can produce a lot; cap it like a file body.
    static let bodyCharCap = 2000
}
