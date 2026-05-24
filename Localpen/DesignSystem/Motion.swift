import SwiftUI

// Motion specs per DESIGN.md §2.6.
// All easing: cubic-bezier(0.22, 1, 0.36, 1) = ease-out-quart.
enum Motion {
    static let appear     = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let dismiss    = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.12)
    static let focusMove  = Animation.linear(duration: 0.10)
    static let menuToResult = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.20)
    static let acceptFlash  = Animation.linear(duration: 0.10)
    static let errorAppear  = Animation.linear(duration: 0.15)
    static let caretBlink   = Animation.easeInOut(duration: 0.425)
}
