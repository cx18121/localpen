import Foundation

/// Files-context configuration (ADR 0019, source #1): the user's opt-in toggle for
/// reading "the file you have open" as ask context. No new system permission — the
/// frontmost document is read via the AX `kAXDocumentAttribute` on the focused window,
/// reusing the Accessibility permission Localpen already holds. `isActive` is the
/// hot-path gate the `FilesContextSource` consults before doing any AX/file work.
enum FilesAccess {
    private static let enabledKey = "filesContextEnabled"

    /// The user's Settings toggle. Default false — off until enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hot-path gate. (No URL/feed to also require, unlike calendar — the gate is
    /// just the toggle; authorization is the shared Accessibility trust.)
    static var isActive: Bool { isEnabled }

    /// Max characters of file body that ride along as context — mirrors the brain's
    /// `perPageCharCap` so one open file can't blow the prompt budget.
    static let bodyCharCap = 1200
}
