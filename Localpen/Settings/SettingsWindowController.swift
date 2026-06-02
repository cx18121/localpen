import AppKit
import SwiftUI

/// Owns the on-demand Settings window — an AppKit `NSTabViewController` with the
/// System-Preferences toolbar look (the SwiftUI `Settings` scene auto-opens at launch on
/// macOS 14, so it's avoided). Extracted from `AppDelegate` so window management isn't
/// tangled into the app-lifecycle object.
///
/// As an LSUIElement (accessory) app Localpen has no Dock icon and never appears in ⌘-Tab,
/// so a backgrounded Settings window would be unreachable. This flips the activation policy
/// to `.regular` while the window is open and back to `.accessory` on close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let registry: ModelRegistry
    private let persistence: Persistence?
    private let switchModel: (String) -> Void
    private var window: NSWindow?

    init(registry: ModelRegistry, persistence: Persistence?, switchModel: @escaping (String) -> Void) {
        self.registry = registry
        self.persistence = persistence
        self.switchModel = switchModel
    }

    func show() {
        NSApp.setActivationPolicy(.regular)

        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            centerInVisibleFrame(existing)
            return
        }

        // Native System-Preferences look: an NSTabViewController with `.toolbar` style renders
        // icon+label tabs in a unified toolbar. Each pane is a SwiftUI grouped Form that fills
        // the content area (flexible frame) so the window stays user-resizable.
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar

        func tab(_ title: String, _ symbol: String, _ root: some View) -> NSTabViewItem {
            let hc = NSHostingController(
                rootView: root.frame(minWidth: 440, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity))
            let item = NSTabViewItem(viewController: hc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }

        tabVC.addTabViewItem(tab("General", "gear", GeneralSettingsView()))
        tabVC.addTabViewItem(tab("Model", "cube",
            ModelPickerView(registry: registry,
                            switchModel: { [weak self] id in self?.switchModel(id) })))
        tabVC.addTabViewItem(tab("History", "clock.arrow.circlepath",
            HistorySettingsView(persistence: persistence)))

        let window = NSWindow(contentViewController: tabVC)
        window.title = "Localpen Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 480, height: 320))
        window.contentMinSize = NSSize(width: 440, height: 220)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        centerInVisibleFrame(window)
    }

    /// When the Settings window closes, drop back to accessory (menu-bar-only) so the app
    /// leaves no Dock tile / ⌘-Tab entry behind.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Center a window within the active screen's `visibleFrame` — which excludes the menu bar
    /// AND the notch inset — so the title bar can never land under the notch. Re-applied on the
    /// next runloop because the SwiftUI panes set their size after first layout, and AppKit
    /// keeps the top-left fixed as the window grows (which tucked the title bar under the notch
    /// when we centered pre-sizing).
    private func centerInVisibleFrame(_ window: NSWindow) {
        let place = { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let vis = screen.visibleFrame
            var f = window.frame
            f.origin.x = (vis.midX - f.width / 2).rounded()
            f.origin.y = (vis.midY - f.height / 2).rounded()
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
            window.setFrame(f, display: true)
        }
        place()
        DispatchQueue.main.async(execute: place)   // again after panes size themselves
    }
}
