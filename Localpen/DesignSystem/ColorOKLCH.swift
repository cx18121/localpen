import SwiftUI
import AppKit

// OKLCH → sRGB conversion (Björn Ottosson's reference algorithm).
// Used to translate DESIGN.md §2.1/§2.2 OKLCH tokens into SwiftUI Colors.
extension Color {
    static func oklch(_ L: Double, _ C: Double, _ H: Double, opacity: Double = 1) -> Color {
        let h = H * .pi / 180
        let a = C * cos(h)
        let b = C * sin(h)
        let (r, g, bb) = oklabToSRGB(L: L, a: a, b: b)
        return Color(.sRGB, red: r, green: g, blue: bb, opacity: opacity)
    }

    /// Dynamic color that flips between two Colors based on macOS appearance.
    static func dynamic(light: Color, dark: Color) -> Color {
        let lightNS = NSColor(light)
        let darkNS = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? darkNS : lightNS
        })
    }

    private static func oklabToSRGB(L: Double, a: Double, b: Double) -> (Double, Double, Double) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (gamma(r), gamma(g), gamma(bb))
    }

    private static func gamma(_ c: Double) -> Double {
        let clamped = max(0, min(1, c))
        if clamped <= 0.0031308 { return 12.92 * clamped }
        return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }
}
