import Foundation

// Spacing rhythm per DESIGN.md §2.4. Non-uniform on purpose.
enum Spacing {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 6
    static let s3: CGFloat = 8
    static let s4: CGFloat = 10
    static let s5: CGFloat = 12
    static let s6: CGFloat = 14
    static let s7: CGFloat = 16
    static let s8: CGFloat = 20

    /// Bubble interior insets (conversation turns). Off-grid on purpose — the
    /// bubble rhythm sits between s3/s4 (vertical) and s5/s6 (horizontal).
    static let bubbleInsetV: CGFloat = 9
    static let bubbleInsetH: CGFloat = 13

    static let panelRadius: CGFloat = 10
    static let innerRadius: CGFloat = 6
}
