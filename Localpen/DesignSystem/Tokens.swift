import SwiftUI

// Color tokens per DESIGN.md §2.1 (dark) and §2.2 (light).
// All values translated from OKLCH via Color.oklch.
// Each token is dynamic: appearance flips dark↔light automatically.
enum Tokens {
    // Surfaces
    static let panelBG     = Color.dynamic(
        light: .oklch(0.98, 0.003, 240),
        dark:  .oklch(0.22, 0.008, 240)
    )
    static let panelBG2    = Color.dynamic(
        light: .oklch(0.96, 0.004, 240),
        dark:  .oklch(0.24, 0.009, 240)
    )
    static let panelBorder = Color.dynamic(
        light: .oklch(0.80, 0.010, 240),
        dark:  .oklch(0.32, 0.012, 240)
    )
    static let hairline    = Color.dynamic(
        light: .oklch(0.85, 0.008, 240),
        dark:  .oklch(0.28, 0.010, 240)
    )
    /// Tint laid over the vibrancy blur so body text keeps contrast while the
    /// surface still reads as translucent glass. See PanelSurface.
    /// Light mode runs nearly opaque: the airy 50% glass let bright/busy desktop
    /// content bleed through and wreck text contrast, so light prioritizes
    /// legibility (a frosted-but-solid surface) while dark keeps more glass.
    static let panelTint   = Color.dynamic(
        light: .oklch(0.98, 0.003, 240, opacity: 0.90),
        dark:  .oklch(0.17, 0.008, 240, opacity: 0.42)
    )
    /// Subtle translucent band differentiating the footer / result-toolbar
    /// chrome from the body without becoming an opaque slab over the glass.
    static let chromeTint  = Color.dynamic(
        light: .oklch(0.20, 0.006, 240, opacity: 0.05),
        dark:  .oklch(0.96, 0.006, 240, opacity: 0.06)
    )
    /// Faint top inner-highlight that gives the panel a glass edge.
    static let glassEdge   = Color.dynamic(
        light: .oklch(1.00, 0.000, 240, opacity: 0.45),
        dark:  .oklch(1.00, 0.000, 240, opacity: 0.10)
    )

    // Text
    static let text        = Color.dynamic(
        light: .oklch(0.20, 0.008, 240),
        dark:  .oklch(0.94, 0.006, 240)
    )
    static let textSoft    = Color.dynamic(
        light: .oklch(0.34, 0.008, 240),
        dark:  .oklch(0.78, 0.008, 240)
    )
    static let textMute    = Color.dynamic(
        light: .oklch(0.42, 0.010, 240),
        dark:  .oklch(0.58, 0.008, 240)
    )
    static let textFaint   = Color.dynamic(
        light: .oklch(0.52, 0.010, 240),
        dark:  .oklch(0.44, 0.008, 240)
    )

    // Accent (desaturated teal)
    static let accent      = Color.dynamic(
        light: .oklch(0.52, 0.10, 200),
        dark:  .oklch(0.78, 0.085, 200)
    )
    static let accentTint  = Color.dynamic(
        light: .oklch(0.52, 0.10, 200, opacity: 0.14),
        dark:  .oklch(0.32, 0.022, 200, opacity: 0.5)
    )
    static let accentMute  = Color.dynamic(
        light: .oklch(0.52, 0.08, 200, opacity: 0.5),
        dark:  .oklch(0.40, 0.030, 200, opacity: 0.6)
    )
    static let accentError = Color.dynamic(
        light: .oklch(0.55, 0.14, 28),
        dark:  .oklch(0.72, 0.10, 28)
    )
}
