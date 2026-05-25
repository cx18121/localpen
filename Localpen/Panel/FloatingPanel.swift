import AppKit

final class FloatingPanel: NSPanel {
    /// All non-text-input keyboard events flow through here.
    /// Return `true` to consume the event; `false` to let it propagate
    /// (e.g., so NSTextView still handles text input).
    var onKeyDown: ((NSEvent) -> Bool)?

    /// When set, the panel keeps this Y as its fixed TOP edge across
    /// content-driven resizes, so it grows downward instead of jumping
    /// vertically between states. nil = normal AppKit behavior.
    var pinnedTopY: CGFloat?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let topY = pinnedTopY {
            r.origin.y = topY - r.height
        }
        super.setFrame(r, display: flag)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false   // sidebar feel — pinned, not draggable
        self.hasShadow = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        // Per DESIGN.md §7: follow macOS system appearance. No forced theme.
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // NSResponder's Escape handler. Catches Esc even when an NSTextView
        // is first responder (which otherwise swallows it silently).
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        )
        if let esc, onKeyDown?(esc) == true { return }
        super.cancelOperation(sender)
    }
}
