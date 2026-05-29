import ServiceManagement
import os

// Login-item registration for the main app via SMAppService (macOS 13+; our
// target is 14+). Always-on menu-bar apps are expected to relaunch on login —
// this is the user-facing toggle's backing store, the SMAppService status IS
// the source of truth (no separate UserDefaults to drift out of sync).
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "app.localpen.Localpen", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                log.error("login-item \(newValue ? "register" : "unregister") failed: \(error.localizedDescription)")
            }
        }
    }
}
