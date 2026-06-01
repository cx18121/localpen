import Foundation

/// Brain enablement + vault location (ADR 0014). Mirrors `CalendarAccess`: a cheap,
/// synchronous UserDefaults-backed gate the ask path consults. `isActive` off ⇒ the
/// ask prompt is byte-identical to today's (`ContextEngine` returns calendar-only).
enum BrainAccess {
    private static let enabledKey = "brain.enabled"
    private static let vaultRootKey = "brain.vaultRoot"

    /// The user's Settings toggle. Default false — off until enabled.
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The Obsidian vault Localpen indexes. Defaults to `~/Documents/cxkb`; overridable.
    static var vaultRoot: URL {
        get {
            if let s = UserDefaults.standard.string(forKey: vaultRootKey), !s.isEmpty {
                return URL(fileURLWithPath: s)
            }
            return Self.defaultVaultRoot
        }
        set { UserDefaults.standard.set(newValue.path, forKey: vaultRootKey) }
    }

    static var defaultVaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/cxkb", isDirectory: true)
    }
}
