import SwiftUI

// Approximate dark-theme tokens from DESIGN.md §2.1.
// M5 replaces these with proper OKLCH→sRGB conversion + light theme.
enum Tokens {
    // Surfaces
    static let panelBG       = Color(red: 0.155, green: 0.155, blue: 0.175)
    static let panelBG2      = Color(red: 0.180, green: 0.180, blue: 0.200)
    static let panelBorder   = Color(red: 0.240, green: 0.240, blue: 0.270)
    static let hairline      = Color(red: 0.205, green: 0.205, blue: 0.235)

    // Text
    static let text          = Color(red: 0.920, green: 0.920, blue: 0.940)
    static let textSoft      = Color(red: 0.740, green: 0.740, blue: 0.760)
    static let textMute      = Color(red: 0.520, green: 0.520, blue: 0.550)
    static let textFaint     = Color(red: 0.380, green: 0.380, blue: 0.410)

    // Accent (desaturated teal)
    static let accent        = Color(red: 0.450, green: 0.780, blue: 0.850)
    static let accentTint    = Color(red: 0.450, green: 0.780, blue: 0.850).opacity(0.18)
    static let accentMute    = Color(red: 0.380, green: 0.640, blue: 0.700).opacity(0.6)
    static let accentError   = Color(red: 0.880, green: 0.500, blue: 0.460)
}
