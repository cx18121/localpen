import Foundation
import AppKit

// Per-bundle-ID panel anchors per SWIFTUI-SPEC.md §4.3.
// Stored in UserDefaults as nested JSON-encodable dicts:
//   [sourceBundleID: [displayUUID: [x, y, w, h]]]
@MainActor
final class AnchorStore {
    private let defaultsKey = "PanelAnchors"
    private let panelSize = NSSize(width: 360, height: 320)

    func read(bundleID: String?, screen: NSScreen?) -> NSPoint {
        if let bundleID, let screen,
           let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: [String: Double]]],
           let appDict = dict[bundleID],
           let stored = appDict[Self.displayID(for: screen)] {
            return NSPoint(x: stored["x"] ?? 0, y: stored["y"] ?? 0)
        }
        return defaultPlacement(on: screen)
    }

    func write(bundleID: String?, screen: NSScreen?, origin: NSPoint) {
        guard let bundleID, let screen else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: [String: Double]]]) ?? [:]
        var appDict = dict[bundleID] ?? [:]
        appDict[Self.displayID(for: screen)] = ["x": origin.x, "y": origin.y]
        dict[bundleID] = appDict
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }

    func defaultPlacement(on screen: NSScreen?) -> NSPoint {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.maxX - panelSize.width - 24,
            y: frame.midY - panelSize.height / 2
        )
    }

    private static func displayID(for screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "default"
        }
        return "\(n.uint32Value)"
    }
}
