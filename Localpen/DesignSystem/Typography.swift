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
    static let kbdGlyph = Font.system(size: 11, weight: .medium, design: .monospaced)

    // First-run / Settings
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let subhead = Font.system(size: 11, weight: .regular)
}
