import SwiftUI
import AppKit

/// An NSTextView that grows to exactly fit its content (no scrolling, no
/// clipping) by reporting its laid-out height as its intrinsic size. Also wires
/// into the panel's keyboard model: auto-focus, Esc/Tab blur back to the menu,
/// and reporting first-responder state for the field's accent border.
///
/// Replaces the earlier SwiftUI TextEditor + invisible-mirror approach, whose
/// wrapping never matched the real text view exactly and clipped long text.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var autoFocus: Bool = false
    var focusTick: Int = 0
    var fontSize: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GrowingNSTextView {
        let tv = GrowingNSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.string = text
        tv.onFocusChange = { focused in
            // Avoid mutating SwiftUI state during view update.
            DispatchQueue.main.async { context.coordinator.parent.isFocused = focused }
        }
        if autoFocus { context.coordinator.pendingFocus = true }
        return tv
    }

    func updateNSView(_ tv: GrowingNSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            tv.invalidateIntrinsicContentSize()
        }
        if context.coordinator.lastTick != focusTick {
            context.coordinator.lastTick = focusTick
            context.coordinator.pendingFocus = true
        }
        if context.coordinator.pendingFocus {
            context.coordinator.pendingFocus = false
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        var lastTick: Int
        var pendingFocus = false

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
            self.lastTick = parent.focusTick
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        // Esc and Tab blur the editor so focus returns to the action menu.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                textView.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

final class GrowingNSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    private var lastWidth: CGFloat = -1

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        return NSSize(width: NSView.noIntrinsicMetric, height: used + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Re-measure when the width changes (wrapping shifts); guarded so a
        // height-only change can't start a layout loop.
        if newSize.width != lastWidth {
            lastWidth = newSize.width
            invalidateIntrinsicContentSize()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}
