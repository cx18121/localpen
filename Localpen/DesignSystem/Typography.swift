import SwiftUI

// Typography scale per DESIGN.md §2.3.
// System font stack — no custom fonts.
enum Typography {
    static let selection = Font.system(size: 14, weight: .regular)
    static let selectionMeta = Font.system(size: 11, weight: .regular)
    static let menuRow = Font.system(size: 14, weight: .regular)
    static let menuRowFocused = Font.system(size: 14, weight: .medium)
    static let result = Font.system(size: 15, weight: .regular)
    static let footerHint = Font.system(size: 12, weight: .regular)
    static let pill = Font.system(size: 11, weight: .medium)
    /// Keyboard-hint glyph face. Rounded·semibold (not mono) is deliberate: the 2026-05
    /// "legible kbd hints" polish found mono 11 too thin inside the keycap chip. KbdHint
    /// is the single component that renders these, so this token is its one source.
    static let kbdGlyph = Font.system(size: 11, weight: .semibold, design: .rounded)
    /// Small-caps group-label face (with `.tracking(0.9)` applied at the call site).
    /// Shared by `SectionHeader` and `ActionMenuView`'s fixed-height group headers so
    /// the two never drift — the menu's headers can't use SectionHeader (highlight math).
    static let sectionHeader = Font.system(size: 10, weight: .semibold)

    // SF Symbol glyph sizes (applied via `.font` on Image). Two sizes only, so chrome
    // icons don't drift: `chromeIcon` for tappable chrome glyphs (matches MenuRow's leading
    // icon), `microGlyph` for in-chip / inline meta marks.
    static let chromeIcon = Font.system(size: 13)
    static let microGlyph = Font.system(size: 9, weight: .medium)

    // First-run / Settings
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let subhead = Font.system(size: 11, weight: .regular)
    /// Monospaced face for technical config fields (iCal URLs, vault path) in Settings.
    static let mono = Font.system(size: 11, design: .monospaced)
}
