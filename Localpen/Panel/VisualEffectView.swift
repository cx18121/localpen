import SwiftUI
import AppKit

/// Window-vibrancy backdrop for the panel — gives it the translucent, layered
/// macOS surface feel (Spotlight / Raycast). A tint sits over the blur so body
/// text keeps its contrast. Falls back to a solid surface when the user has
/// Reduce Transparency enabled.
struct PanelSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Tokens.panelBG
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Tokens.panelTint)
        }
    }
}

/// Thin SwiftUI wrapper over NSVisualEffectView.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
