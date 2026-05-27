import SwiftUI
import AppKit
import Combine
import DynamicNotchKit

/// The single presentation seam between `PanelController` and DynamicNotchKit.
/// `PanelController` never touches `DynamicNotch` directly — it calls `expand()`
/// to show the working surface and `idle()` to return to the calm resting notch.
///
/// The notch is **never `hide()`d** except on app teardown: at rest it sits in the
/// `compact` state showing a faint accent dot (`NotchDot`), which is what makes
/// hover/click invocation possible (DynamicNotchKit only tracks hover when the
/// window exists, and `hide()` deinitializes it).
///
/// Invocation routes back to the controller via callbacks:
/// - `onHoverOpen` — pointer dwelled on the resting notch (~`dwell`)
/// - `onClickOpen` — the resting dot was clicked
/// - `onClickAway` — a click landed outside while the surface was expanded
/// - `handleKey` / `handleEditorKey` — keyboard, routed responder-aware (see below)
@MainActor
final class NotchPresenter {
    // Set by AppDelegate after construction (the controller doesn't exist yet at init).
    var onHoverOpen: (() -> Void)?
    var onClickOpen: (() -> Void)?
    var onClickAway: (() -> Void)?
    var handleKey: ((NSEvent) -> Bool)?
    var handleEditorKey: ((NSEvent) -> Bool)?

    /// Pointer dwell before hover opens the notch. Quick passes (reaching for the
    /// menu bar) are ignored; the pointer must linger this long.
    private let dwell: Duration = .milliseconds(250)
    /// After dismiss-to-idle, ignore hover-open briefly so the surface doesn't
    /// immediately re-open under a pointer that's still parked over the notch.
    private let reopenCooldown: Duration = .milliseconds(350)

    private var notch: DynamicNotch<AnyView, EmptyView, NotchDot>!
    private var keyMonitor: Any?
    private var clickAwayMonitor: Any?
    private var hoverCancellable: AnyCancellable?
    private var dwellTask: Task<Void, Never>?

    /// Our own view of presentation state — DynamicNotch's `state` is package-internal.
    private var isExpanded = false
    private var cooldownUntil: ContinuousClock.Instant?

    /// `expanded` builds the working surface (PanelView). Built once and hosted in
    /// both states (only shown when expanded).
    init(expanded: @escaping () -> AnyView) {
        notch = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            expanded: expanded,
            compactTrailing: { [weak self] in
                NotchDot { self?.onClickOpen?() }
            }
        )
        // Snappier open: skip the 250ms intermediate-hide step DynamicNotchKit
        // otherwise inserts when converting compact→expanded, and use tighter,
        // less-bouncy curves so the surface feels crisp rather than springy.
        notch.transitionConfiguration = .init(
            openingAnimation: .snappy(duration: 0.20),
            closingAnimation: .snappy(duration: 0.16),
            conversionAnimation: .snappy(duration: 0.18),
            skipIntermediateHides: true
        )
        observeHover()
        installKeyMonitor()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Presentation

    private var targetScreen: NSScreen { NSScreen.notched() ?? NSScreen.screens[0] }

    /// Animate the working surface open WITHOUT taking key focus. Used for the
    /// instant open: the surface appears immediately while the source app stays
    /// frontmost (so the capture ⌘C still lands there). Call `focus()` once capture
    /// is done to take keyboard focus.
    func expand() async {
        isExpanded = true
        dwellTask?.cancel()
        installClickAwayMonitor()
        await notch.expand(on: targetScreen)
    }

    /// Take key focus so the input editor can type. Non-activating, so Localpen
    /// never comes to the foreground. Safe to call repeatedly.
    func focus() {
        notch.windowController?.window?.makeKey()
    }

    /// Give up key-window status so a synthetic paste lands in the source app, not
    /// our panel. The notch sits at `.screenSaver` level and holds key focus (needed
    /// for typing); without resigning it first, the just-reactivated source app never
    /// receives the ⌘V. Also deactivates Localpen so the source app is unambiguously
    /// frontmost for the keystroke.
    func resignKey() {
        notch.windowController?.window?.resignKey()
        NSApp.deactivate()
    }

    /// Return to the calm resting notch (compact dot). Not `hide()` — we keep the
    /// window alive so hover/click still work.
    func idle() async {
        isExpanded = false
        cooldownUntil = ContinuousClock.now.advanced(by: reopenCooldown)
        removeClickAwayMonitor()
        await notch.compact(on: targetScreen)
    }

    /// Bring up the resting notch at launch.
    func showIdle() async {
        await notch.compact(on: targetScreen)
    }

    // MARK: - Hover → dwell → open

    private func observeHover() {
        hoverCancellable = notch.$isHovering
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering in
                MainActor.assumeIsolated { self?.hoverChanged(hovering) }
            }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard !isExpanded else { return }
        guard hovering else { dwellTask?.cancel(); return }
        if let until = cooldownUntil, ContinuousClock.now < until { return }
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.dwell)
            guard !Task.isCancelled, !self.isExpanded else { return }
            self.onHoverOpen?()
        }
    }

    // MARK: - Keyboard (responder-aware, scoped to the notch window)

    /// A local key monitor scoped to the notch window. When a text editor owns the
    /// first-responder slot, ordinary editing keys pass straight through; only the
    /// keys the controller must override for the current phase are intercepted
    /// (`handleEditorKey`). Otherwise the key drives the panel (`handleKey`). Events
    /// for any other window (Settings/About) are ignored.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.notch.windowController?.window,
                  event.window === window else { return event }
            return MainActor.assumeIsolated {
                let editorFocused = window.firstResponder is NSTextView
                let consumed = editorFocused
                    ? (self.handleEditorKey?(event) ?? false)
                    : (self.handleKey?(event) ?? false)
                return consumed ? nil : event
            }
        }
    }

    // MARK: - Click-away

    private func installClickAwayMonitor() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.onClickAway?() }
        }
    }

    private func removeClickAwayMonitor() {
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m); clickAwayMonitor = nil }
    }
}

/// The calm resting indicator shown beside the notch — a small accent dot. Clicking
/// it opens the assistant (hover-dwell does too, handled by the presenter).
struct NotchDot: View {
    let onTap: () -> Void

    var body: some View {
        Circle()
            .fill(Tokens.accent)
            .frame(width: 6, height: 6)
            .opacity(0.9)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}
