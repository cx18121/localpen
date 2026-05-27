# Notch Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Localpen's UI from the hotkey-summoned right-edge `FloatingPanel` to a single MacBook-notch-anchored surface built on DynamicNotchKit, reusing the existing `PanelView` and state machine.

**Architecture:** Introduce a `NotchPresenter` seam that wraps `DynamicNotchKit` (expand/hide, built-in-display targeting, capture-ordering). `PanelController` keeps its state machine / streaming / persistence and talks to `NotchPresenter` instead of `FloatingPanel`. Keyboard moves to a responder-aware `NSEvent` monitor that yields editing keys to a first-responder `NSTextView` and preserves Escape forwarding. One real logic change: `acceptResult` must honor `session.canPasteBack` (needed for the new no-source hover/click entry).

**Tech Stack:** Swift 5.10, AppKit + SwiftUI, macOS 14 target, XcodeGen (`project.yml` → gitignored `.xcodeproj`), SPM (KeyboardShortcuts, GRDB, TOMLKit, **+ DynamicNotchKit**), XCTest (logic layer only).

**Source of truth:** `docs/superpowers/specs/2026-05-27-notch-assistant-design.md` (revised post-adversarial-review).

---

## Testing approach (read before starting)

This plan deliberately mixes two verification modes, matching the repo's established posture (spec §Testing):

- **TDD with XCTest** — only for genuinely unit-testable logic with no AppKit/NSScreen/NSPanel dependency: the `acceptResult` `canPasteBack` branch (Task 5) and the pure notched-display resolver (Task 3). Write the failing test first for these.
- **Spike checklist + build-verify** — for everything touching DynamicNotchKit, focus, key routing, and presentation. The repo has **no view/AppKit unit tests** and will not gain them here. Do **not** invent XCTest cases that try to assert NSPanel focus or notch geometry — they can't run headless reliably. "Verified" for these tasks means: the project builds clean (`xcodebuild build`), the existing 22 tests still pass, and the relevant manual checklist item is ticked.

**Build / test commands used throughout:**

```bash
# Regenerate the Xcode project after any project.yml change:
xcodegen generate

# Build (presentation/integration tasks):
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS'

# Test (logic tasks + regression after every task):
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS'
```

A passing test run ends with `** TEST SUCCEEDED **` and `Executed 22 tests, with 0 failures`. After logic tasks add tests, the count rises (note the new expected total in that task).

**Spike gate (Task 2) is a hard STOP.** If the spike fails any criterion, do not proceed to Task 3+. Report the failure and stop — the fallback is custom-rolling the notch window, which is a separate design cycle.

---

## File structure

**New files:**
- `Localpen/Panel/NotchPresenter.swift` — wraps `DynamicNotch`; owns `expand()`/`hide()`, built-in-display targeting, and the capture-ordering choice. The single seam `PanelController` calls. ~120 lines.
- `Localpen/Panel/NotchDisplay.swift` — pure helper `notchedScreen(from:)` selecting the built-in notched display; testable over a tiny `ScreenInfo` value type. ~30 lines.
- `Localpen/Panel/PanelKeyMonitor.swift` — responder-aware local `NSEvent` key monitor → `PanelController.handleKeyDown`, yielding editing keys to a first-responder `NSTextView` and preserving Escape forwarding. ~70 lines.
- `LocalpenTests/NotchDisplayTests.swift` — tests for the display resolver.
- `LocalpenTests/AcceptPasteBackTests.swift` — tests for the `acceptResult` `canPasteBack` branch.
- `docs/adr/0011-notch-surface-supersedes-floating-slab.md` — supersedes ADR 0001's presentation decision.

**Modified files:**
- `project.yml` — add DynamicNotchKit SPM package + product dependency.
- `Localpen/Panel/PanelController.swift` — route presentation through `NotchPresenter`; add `acceptResult` `canPasteBack` check; add hover/click invoke entry; retire `showPanel`/`hidePanelAnimated`/`sidebarTopLeft`/`installObservers`/`pinnedTopY` usage.
- `Localpen/AppDelegate.swift` — construct `NotchPresenter`, inject into `PanelController`; wire hover/click invoke.
- `docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md` — amend to record the added dependency.

**Retired:**
- `Localpen/Panel/FloatingPanel.swift` — deleted in the final task once nothing references it.

---

## Task 1: Add and verify the DynamicNotchKit dependency

**Files:**
- Modify: `project.yml:8-17` (packages), `project.yml:58-64` (Localpen target dependencies)
- Create (throwaway, deleted in this task): `Localpen/Panel/_NotchAPIProbe.swift`

- [ ] **Step 1: Add the SPM package**

In `project.yml`, under `packages:` (after `TOMLKit`, around line 16), add:

```yaml
  DynamicNotchKit:
    url: https://github.com/MrKai77/DynamicNotchKit
    from: 1.1.0
```

- [ ] **Step 2: Add the product dependency to the Localpen target**

In `project.yml`, in the `Localpen` target's `dependencies:` list (around line 58-64, alongside KeyboardShortcuts/GRDB/TOMLKit), add:

```yaml
      - package: DynamicNotchKit
        product: DynamicNotchKit
```

- [ ] **Step 3: Regenerate and resolve packages**

Run:
```bash
xcodegen generate && xcodebuild -resolvePackageDependencies -project Localpen.xcodeproj -scheme Localpen
```
Expected: package resolves; DynamicNotchKit and its pinned version appear in the resolution output, no errors.

- [ ] **Step 4: Write an API probe to confirm the real signatures**

Create `Localpen/Panel/_NotchAPIProbe.swift`. This confirms the exact 1.1.0 API the later tasks assume (the spec flagged "verify the exact API before committing"). Adjust the symbol names below to whatever the resolved source actually exposes — the point of this step is to make the compiler tell you the truth:

```swift
import SwiftUI
import DynamicNotchKit

// THROWAWAY probe — deleted at the end of Task 1. Exists only to make the
// compiler confirm the DynamicNotchKit 1.1.0 surface the plan relies on:
//  - a DynamicNotch type constructed with a SwiftUI content closure
//  - async expand(on:) / hide() (or whatever the resolved version names them)
@MainActor
func _notchAPIProbe() async {
    let notch = DynamicNotch {
        Text("probe")
    }
    // Confirm the presentation entry point and that a screen can be supplied.
    await notch.expand(on: NSScreen.screens.first ?? NSScreen.main!)
    await notch.hide()
}
```

- [ ] **Step 5: Build the probe and record the real API**

Run:
```bash
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -30
```
If it fails, the error names the correct symbols — fix the probe to match the actual 1.1.0 API (init shape, whether `expand`/`show` is the method, its `on:` label/type, async vs sync). Iterate until it builds. **Write the confirmed signatures as a comment block at the top of the probe**, then copy that comment into the top of `NotchPresenter.swift` when you create it in Task 3. Expected end state: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Delete the probe**

```bash
rm Localpen/Panel/_NotchAPIProbe.swift
xcodegen generate
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: still `** BUILD SUCCEEDED **` (probe was self-contained). Keep the confirmed-API comment text in the commit message so Task 3 can use it.

- [ ] **Step 7: Commit**

```bash
git add project.yml
git commit -m "deps: add DynamicNotchKit (notch surface); verified 1.1.0 API

Confirmed API: <paste the real DynamicNotch init + expand/hide signatures here>"
```

---

## Task 2: Throwaway spike — prove keyboard, capture, no-source, and display (HARD GATE)

**Files:**
- Create (throwaway, deleted in Task 8): `Localpen/Panel/_NotchSpike.swift`
- Modify (temporary): `Localpen/AppDelegate.swift` — add a temporary menu item to trigger the spike

This task produces **no production code**. It answers the spec's integration unknowns before any port. Treat all code here as disposable.

- [ ] **Step 1: Build the spike surface**

Create `Localpen/Panel/_NotchSpike.swift` with a `DynamicNotch` hosting a minimal interactive SwiftUI view: a `Button` that toggles a label, and a `TextField` (or an `NSViewRepresentable` wrapping `NSTextView` to mirror `GrowingTextEditor`) that must accept typed input. Expose `@MainActor func runNotchSpike()` that resolves the built-in notched screen (`NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? .main`) and expands the notch on it. Use the confirmed API from Task 1.

```swift
import SwiftUI
import AppKit
import DynamicNotchKit

// THROWAWAY spike — deleted in Task 8. Proves the spec's integration unknowns.
@MainActor
final class _NotchSpike {
    private var notch: DynamicNotch<AnyView>?

    func run() async {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let view = _SpikeContent()
        notch = DynamicNotch { AnyView(view) }
        await notch?.expand(on: screen)   // match Task 1's confirmed signature
    }
}

private struct _SpikeContent: View {
    @State private var tapped = false
    @State private var typed = ""
    var body: some View {
        VStack(spacing: 8) {
            Button(tapped ? "tapped ✓" : "tap me") { tapped.toggle() }
            _SpikeTextView(text: $typed)   // NSTextView-backed; mirrors GrowingTextEditor
                .frame(width: 360, height: 80)
            Text("typed: \(typed)")
        }
        .padding(24)
    }
}

// Minimal NSTextView wrapper so the spike exercises a *real* first responder,
// not SwiftUI's TextField (which routes keys differently).
private struct _SpikeTextView: NSViewRepresentable { /* wrap NSTextView, bind text */ }
```

Fill in `_SpikeTextView` by copying the wrapping pattern from `Localpen/Panel/GrowingTextEditor.swift` (NSViewRepresentable around an NSTextView). Keep it minimal.

- [ ] **Step 2: Add a temporary trigger**

In `AppDelegate.swift`, add a temporary menu item or reuse the hotkey to call `Task { await _NotchSpike().run() }`. Mark it with `// TEMP SPIKE — remove in Task 8`.

- [ ] **Step 3: Build and run the app**

```bash
xcodegen generate
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -3
```
Then run the built app (or via Xcode) and trigger the spike.

- [ ] **Step 4: Run the spike checklist (manual — this is the gate)**

Tick every item. **Any failure → STOP, report, do not continue to Task 3.**

- [ ] Notch expands from the built-in display's notch (not an external monitor, not the floating fallback) when docked to an external display.
- [ ] The button responds to a click while hosted in the notch.
- [ ] The NSTextView accepts typed characters (it can become first responder inside the notch's window).
- [ ] With the NSTextView focused: arrow keys move the caret; Return inserts a newline / behaves as an editor (does NOT trigger any global action); Escape can still be made to dismiss (test that a key monitor can observe Escape even with the text view focused — see Task 4's mechanism).
- [ ] **Capture race:** with text selected in another app (e.g. TextEdit), trigger the hotkey-style path: confirm a synthetic ⌘C issued *before* the notch takes focus captures from the source app even if you click the notch during the modifier-wait window. If you cannot prove non-activating expand, record that option (a) capture-then-present is required (notch must not present until capture returns).
- [ ] **Display:** with the laptop lid open + an external monitor, the notch still targets the built-in notched screen.

- [ ] **Step 5: Record the verdict**

Append a short "Spike findings" section to the spec file (`docs/superpowers/specs/2026-05-27-notch-assistant-design.md`) capturing: which capture-ordering option holds ((a) or (b)), the exact key-routing mechanism that worked (local monitor return-nil-on-NSTextView vs SwiftUI `.onKeyPress`), and any DynamicNotchKit quirks. Downstream tasks read this.

- [ ] **Step 6: Commit the findings (leave spike code in place until Task 8)**

```bash
git add docs/superpowers/specs/2026-05-27-notch-assistant-design.md
git commit -m "spike: verify notch keyboard/capture/display; record findings"
```

---

## Task 3: NotchPresenter seam + notched-display resolver

**Files:**
- Create: `Localpen/Panel/NotchDisplay.swift`
- Create: `Localpen/Panel/NotchPresenter.swift`
- Test: `LocalpenTests/NotchDisplayTests.swift`

- [ ] **Step 1: Write the failing display-resolver test**

Create `LocalpenTests/NotchDisplayTests.swift`:

```swift
import XCTest
@testable import Localpen

final class NotchDisplayTests: XCTestCase {
    func test_picksScreenWithTopSafeArea() {
        let external = ScreenInfo(hasNotch: false, isMain: true)
        let builtin  = ScreenInfo(hasNotch: true,  isMain: false)
        XCTAssertEqual(notchedScreenIndex(from: [external, builtin]), 1)
    }

    func test_fallsBackToMainWhenNoNotch() {
        let a = ScreenInfo(hasNotch: false, isMain: false)
        let b = ScreenInfo(hasNotch: false, isMain: true)
        XCTAssertEqual(notchedScreenIndex(from: [a, b]), 1)   // the main screen
    }

    func test_fallsBackToFirstWhenNoNotchNoMain() {
        let a = ScreenInfo(hasNotch: false, isMain: false)
        XCTAssertEqual(notchedScreenIndex(from: [a]), 0)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: FAIL — `ScreenInfo` / `notchedScreenIndex` undefined.

- [ ] **Step 3: Implement the pure resolver**

Create `Localpen/Panel/NotchDisplay.swift`:

```swift
import AppKit

/// Minimal, testable projection of an NSScreen for display selection.
struct ScreenInfo {
    let hasNotch: Bool   // safeAreaInsets.top > 0
    let isMain: Bool
}

/// Index of the screen the notch surface should target: the built-in notched
/// display if present, else the main screen, else the first. NSScreen.screens
/// is never empty at runtime, but the resolver is total for testability.
func notchedScreenIndex(from screens: [ScreenInfo]) -> Int {
    if let i = screens.firstIndex(where: { $0.hasNotch }) { return i }
    if let i = screens.firstIndex(where: { $0.isMain })  { return i }
    return 0
}

extension NSScreen {
    /// The built-in notched display, resolved via the pure helper above.
    static func notched() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let infos = screens.map {
            ScreenInfo(hasNotch: $0.safeAreaInsets.top > 0, isMain: $0 == NSScreen.main)
        }
        return screens[notchedScreenIndex(from: infos)]
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3
```
Expected: PASS, `Executed 25 tests, with 0 failures` (22 existing + 3 new).

- [ ] **Step 5: Implement NotchPresenter**

Create `Localpen/Panel/NotchPresenter.swift`. Paste the confirmed-API comment from Task 1 at the top. Use the capture-ordering option recorded by the spike (Task 2 findings); the code below is option (a) capture-then-present (the safe default — `present()` is only called after capture completes, so the surface is never interactive during capture):

```swift
import SwiftUI
import AppKit
import DynamicNotchKit

/// The single presentation seam between PanelController and DynamicNotchKit.
/// PanelController never touches DynamicNotch directly. Targets the built-in
/// notched display (NSScreen.notched()).
@MainActor
final class NotchPresenter {
    private var notch: DynamicNotch<AnyView>?
    private let content: () -> AnyView

    /// `content` builds the hosted SwiftUI (PanelView) lazily so the presenter
    /// can be constructed before the controller is fully wired.
    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    /// Show the surface on the built-in notched display. Idempotent.
    func present() async {
        let screen = NSScreen.notched() ?? NSScreen.main!
        if notch == nil { notch = DynamicNotch { self.content() } }
        await notch?.expand(on: screen)   // match Task 1's confirmed signature
    }

    /// Hide the surface. Safe to call when not presented.
    func hide() async {
        await notch?.hide()
    }
}
```

If the spike found option (b) (non-interactive pre-capture) is needed, add a `presentNonInteractive()` that expands a non-focusable placeholder and a `promoteToInteractive()` that swaps content — but only if Task 2 proved capture-then-present insufficient. Default: ship option (a).

- [ ] **Step 6: Build**

```bash
xcodegen generate
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Localpen/Panel/NotchDisplay.swift Localpen/Panel/NotchPresenter.swift LocalpenTests/NotchDisplayTests.swift project.yml
git commit -m "feat: NotchPresenter seam + notched-display resolver"
```

---

## Task 4: Responder-aware key monitor

**Files:**
- Create: `Localpen/Panel/PanelKeyMonitor.swift`

This replaces `FloatingPanel.keyDown`/`cancelOperation` routing. The invariant (spec §Keyboard routing): keys reach `handleKeyDown` **only when no NSTextView owns the command**, and Escape is forwarded even from a focused editor. Use the exact mechanism the spike confirmed (Task 2 findings); the code below is the local-monitor variant.

- [ ] **Step 1: Implement the monitor**

Create `Localpen/Panel/PanelKeyMonitor.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// Responder-aware keyboard bridge for the notch surface. A local NSEvent
/// monitor lets the focused NSTextView keep ordinary editing keys, forwards the
/// rest to PanelController.handleKeyDown, and always forwards Escape (preserving
/// the old FloatingPanel.cancelOperation behavior the notch window lacks).
@MainActor
final class PanelKeyMonitor {
    private var monitor: Any?
    private let handle: (NSEvent) -> Bool

    init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                let isEscape = Int(event.keyCode) == kVK_Escape
                let editorFocused = (event.window?.firstResponder is NSTextView)
                // Editor owns ordinary editing keys — but Escape must always reach
                // the panel handler (the NSTextView would otherwise swallow it).
                if editorFocused && !isEscape { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild build -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` (not wired yet; just compiles).

- [ ] **Step 3: Commit**

```bash
git add Localpen/Panel/PanelKeyMonitor.swift
git commit -m "feat: responder-aware PanelKeyMonitor (yields editing keys, forwards Escape)"
```

---

## Task 5: acceptResult honors canPasteBack (TDD — real logic change)

**Files:**
- Modify: `Localpen/Panel/PanelController.swift:283-323` (`acceptResult`)
- Test: `LocalpenTests/AcceptPasteBackTests.swift`

**Why:** Today `acceptResult`'s `.revise` branch (`PanelController.swift:308-321`) calls `textIO.pasteBack` unconditionally. The new hover/click entry (Task 6) creates a `canPasteBack: false` session that can reach `.result`, so accepting would synthesize ⌘V into whatever app is frontmost. `acceptTurn` already guards on `session.canPasteBack` (`:794`); `acceptResult` must match.

The current `acceptResult` is not unit-testable as-is (it reads `state`, mutates the panel, posts real paste events). Extract the paste/clipboard decision into a pure function and test *that*.

- [ ] **Step 1: Write the failing test**

Create `LocalpenTests/AcceptPasteBackTests.swift`:

```swift
import XCTest
@testable import Localpen

final class AcceptPasteBackTests: XCTestCase {
    // revise + pasteable → paste back into source
    func test_reviseAndPasteable_pastesBack() {
        XCTAssertEqual(acceptDisposition(operationClass: .revise, canPasteBack: true), .pasteBack)
    }
    // revise but no source (resumed / hover-click) → copy, never paste
    func test_reviseNoSource_copies() {
        XCTAssertEqual(acceptDisposition(operationClass: .revise, canPasteBack: false), .copyToClipboard)
    }
    // create-class always copies, regardless of pasteability
    func test_create_alwaysCopies() {
        XCTAssertEqual(acceptDisposition(operationClass: .create, canPasteBack: true), .copyToClipboard)
        XCTAssertEqual(acceptDisposition(operationClass: .create, canPasteBack: false), .copyToClipboard)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: FAIL — `acceptDisposition` / `AcceptDisposition` undefined.

- [ ] **Step 3: Add the pure disposition function**

In `PanelController.swift`, add near `acceptResult` (file-scope enum + method, both `@testable`-visible):

```swift
/// Where an accepted result should go. Pure decision so it can be unit-tested
/// without posting real paste events.
enum AcceptDisposition: Equatable { case pasteBack, copyToClipboard }

/// create-class output never pastes over the source; revise pastes only when the
/// session has a live source field (canPasteBack). Mirrors acceptTurn's guard.
/// `OperationClass` is nested in `Action` (Action.swift:57), so the parameter type
/// is `Action.OperationClass`.
func acceptDisposition(operationClass: Action.OperationClass, canPasteBack: Bool) -> AcceptDisposition {
    guard case .revise = operationClass, canPasteBack else { return .copyToClipboard }
    return .pasteBack
}
```

(Confirmed against `Localpen/Models/Action.swift:57-68`: `enum OperationClass` with `.create`/`.revise`, exposed via `action.operationClass`.)

- [ ] **Step 4: Run the test to confirm it passes**

```bash
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3
```
Expected: PASS, `Executed 28 tests, with 0 failures` (25 + 3 new).

- [ ] **Step 5: Route acceptResult through the disposition**

Replace `acceptResult`'s `switch action.operationClass` body (`PanelController.swift:300-322`) so the `.revise` branch consults the disposition. The `.create` path is unchanged in effect; the `.revise` path now copies instead of pasting when `!session.canPasteBack`:

```swift
        switch acceptDisposition(operationClass: action.operationClass, canPasteBack: session.canPasteBack) {
        case .copyToClipboard:
            // New artifact, OR a revise with no live source field (hover/click,
            // resumed thread): leave it on the clipboard, never paste.
            writeToClipboard(text)
            state = .hidden
            current = nil
            hidePanelAnimated()
        case .pasteBack:
            let capture = session.capture
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.textIO.pasteBack(result: text, capture: capture)
                guard self.current === session else { return }
                if result == .skipped {
                    self.state = .visible(PanelContext(selection: sel, action: action), .error(.pasteBackFallback))
                } else {
                    self.state = .hidden
                    self.current = nil
                    self.hidePanelAnimated()
                }
            }
        }
```

(`hidePanelAnimated()` here is still the FloatingPanel call; Task 6 swaps it for the presenter. Leave it for now so this task stays focused and the build stays green.)

- [ ] **Step 6: Build + full test run**

```bash
xcodegen generate
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3
```
Expected: `Executed 28 tests, with 0 failures`, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Localpen/Panel/PanelController.swift LocalpenTests/AcceptPasteBackTests.swift
git commit -m "fix: acceptResult honors canPasteBack (no paste into frontmost for no-source sessions)"
```

---

## Task 6: Wire PanelController + AppDelegate to the notch; add hover/click entry

**Files:**
- Modify: `Localpen/Panel/PanelController.swift` (capture/show/hide paths, key monitor, hover entry)
- Modify: `Localpen/AppDelegate.swift:57-71` (construct presenter, inject, wire hover/click)

This is the integration task. Verification is build + the manual checklist at the end (no XCTest for focus/presentation, per the testing-approach note).

- [ ] **Step 1: Inject NotchPresenter + PanelKeyMonitor into PanelController**

Add stored properties and init params. Replace the `@ObservationIgnored private var panel: FloatingPanel?` with:

```swift
    @ObservationIgnored private let notch: NotchPresenter
    @ObservationIgnored private var keyMonitor: PanelKeyMonitor?
```

Add `notch: NotchPresenter` to `init` (PanelController is a plain `@Observable final class`, no superclass / no `super.init`). Store `notch`, then as the **last line of `init`** create the key monitor (all stored properties are initialized by then, so `self` is usable):
```swift
        self.keyMonitor = PanelKeyMonitor { [weak self] event in self?.handleKeyDown(event) ?? false }
```

- [ ] **Step 2: Replace showPanel() with the presenter**

Rewrite the show path. `captureAndShow()` (`PanelController.swift:403-432`) keeps capture-first ordering (option (a)); replace the trailing `showPanel()` with:

```swift
        keyMonitor?.start()
        Task { await notch.present() }
```

Delete `showPanel()` (`:462-502`), `sidebarTopLeft()` (`:446-460`), and `installObservers()` (`:532-552`) — the global click-outside monitor and mouse-input monitor. (Click-away dismiss for the notch is handled by DynamicNotchKit's own outside-interaction behavior, confirmed in the spike; if the spike found it isn't, re-add a click-outside monitor adapted to the notch window here. The mouse-input `lastInputSource` tracking moves to the key monitor's sibling — keep a minimal local mouse monitor if hover-focus stealing was a problem; otherwise drop it.)

- [ ] **Step 3: Replace hidePanelAnimated() with the presenter**

Delete `hidePanelAnimated()` (`:504-530`). Replace every call site (`dismiss()` `:147`, `acceptResult` both branches, `retryFromError` `.pasteBackFallback` `:384`, `acceptTurn` `:798,:808`) with:
```swift
        keyMonitor?.stop()
        Task { await notch.hide() }
```
Add a small private helper `private func dismissPresentation() { keyMonitor?.stop(); Task { await notch.hide() } }` and call it at those sites to stay DRY.

- [ ] **Step 4: Remove pinnedTopY usage**

`pinnedTopY` lived on FloatingPanel; the notch grows downward natively. Remove the `panel.pinnedTopY = ...` line (was in `showPanel`, already deleted). No replacement needed.

- [ ] **Step 5: Add the hover/click invoke entry (non-pasteable session)**

Add a method mirroring `captureAndShow` but with no capture and a non-pasteable session (reusing the `resumeThread` contract at `:844-846`):

```swift
    /// Hover/click invoke: open the surface with no capture. The session is
    /// non-pasteable (no source field), so accept copies rather than pasting.
    func showFromHover() {
        bumpConvEpoch()
        isAccepting = false
        sessionCounter += 1
        current = PanelSession(id: sessionCounter, capture: .empty,
                               hotkeyTime: ContinuousClock.now, canPasteBack: false)
        inputText = ""
        state = .visible(PanelContext(), .empty)
        keyMonitor?.start()
        Task { await notch.present() }
    }
```

- [ ] **Step 6: Construct and wire the presenter in AppDelegate**

In `AppDelegate.swift` (around `:57`), build the presenter that hosts `PanelView`, then pass it to the controller. Because `PanelView(controller:)` needs the controller and the presenter needs the content closure, use a deferred reference:

```swift
        var controllerRef: PanelController!
        let notch = NotchPresenter { AnyView(PanelView(controller: controllerRef)) }
        let panel = PanelController(
            textIO: textIO, streaming: streaming, persistence: persistence,
            registry: registry, llamaServer: server, notch: notch,
            openSettings: { [weak self] in self?.openSettings() }
        )
        controllerRef = panel
        panelController = panel
```

Wire hover/click: connect the notch's hover/click affordance (DynamicNotchKit's interaction, or a status-item/notch click per spike findings) to `panel.showFromHover()`. If 1.1.0 exposes no hover hook, defer hover to a follow-up and keep hotkey-only for v1 (note it in the spec); click-to-open via the existing hotkey path already works.

- [ ] **Step 7: Build + full test run**

```bash
xcodegen generate
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3
```
Expected: `Executed 28 tests, with 0 failures`, `** TEST SUCCEEDED **`. (FloatingPanel.swift still exists and compiles but is now unreferenced — that's fine until Task 8.)

- [ ] **Step 8: Manual integration checklist (run the app)**

- [ ] Hotkey with a selection in another app → notch drops down, selection populates the input, capture still landed (the input shows the source text).
- [ ] Pick Polish → streams → Accept → pastes back into the source app.
- [ ] Hotkey hover/click entry (if wired) → empty state; pick an action with typed input → Accept → result is on the clipboard, nothing pasted into the frontmost app.
- [ ] Keyboard: arrow keys navigate the menu; Tab into the input; type and edit (arrows move caret, not menu); Esc backs out / dismisses; Return submits where expected.
- [ ] Conversation: follow-up promotes, streams, `Use` accepts. Esc dismisses from `.conversing`.
- [ ] Notch appears on the built-in display when docked to an external monitor.

- [ ] **Step 9: Commit**

```bash
git add Localpen/Panel/PanelController.swift Localpen/AppDelegate.swift
git commit -m "feat: route panel presentation through NotchPresenter; add hover/click no-source entry"
```

---

## Task 7: Retire FloatingPanel and the spike

**Files:**
- Delete: `Localpen/Panel/FloatingPanel.swift`
- Delete: `Localpen/Panel/_NotchSpike.swift` (+ the temporary AppDelegate trigger)

- [ ] **Step 1: Confirm nothing references FloatingPanel**

```bash
grep -rn "FloatingPanel\|_NotchSpike\|TEMP SPIKE" Localpen
```
Expected: no matches except the files about to be deleted (and the temporary trigger lines). If `PanelController` or `AppDelegate` still reference `FloatingPanel`, fix those first.

- [ ] **Step 2: Delete the files and the temporary trigger**

```bash
rm Localpen/Panel/FloatingPanel.swift Localpen/Panel/_NotchSpike.swift
```
Remove the `// TEMP SPIKE` trigger lines from `AppDelegate.swift`.

- [ ] **Step 3: Regenerate, build, test**

```bash
xcodegen generate
xcodebuild test -project Localpen.xcodeproj -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3
```
Expected: `Executed 28 tests, with 0 failures`, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: retire FloatingPanel and notch spike (notch surface is live)"
```

---

## Task 8: ADRs

**Files:**
- Modify: `docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md`
- Create: `docs/adr/0011-notch-surface-supersedes-floating-slab.md`

- [ ] **Step 1: Amend ADR 0008 (dependency set)**

Append an "Amendment (2026-05-27)" section recording that DynamicNotchKit was added as a fourth SPM dependency for the notch surface (rationale: notch shape/insets/positioning craft handled by the library; MIT, macOS 13+). Keep the original text intact.

- [ ] **Step 2: Write ADR 0011 (surface supersedes 0001)**

Create `docs/adr/0011-notch-surface-supersedes-floating-slab.md` following the existing ADR format (read `docs/adr/0001-phase-1-quick-action-only.md` for the house template). Content: status Accepted; supersedes the *presentation* decision in ADR 0001 (right-edge floating slab → notch-anchored surface on DynamicNotchKit); note the state machine / capture / persistence are unchanged; record the spike-gated approach and the invariants (capture ordering, no-source sessions, responder-aware keyboard, built-in-display targeting); list "Alternatives considered": custom-rolled notch window (rejected: reimplements DynamicNotchKit's shape/inset craft), two-panel model (rejected in brainstorm), keep the slab (rejected: the notch is the product direction).

- [ ] **Step 3: Update CLAUDE.md SPM dep pointer**

In `CLAUDE.md`, the "SPM deps" line lists three packages. Update it to four (add DynamicNotchKit) and the ADR pointer to include 0011.

- [ ] **Step 4: Commit**

```bash
git add docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md docs/adr/0011-notch-surface-supersedes-floating-slab.md CLAUDE.md
git commit -m "docs: ADR 0011 (notch surface supersedes slab); amend 0008 (DynamicNotchKit dep)"
```

---

## Done

After Task 8: the notch surface is live, FloatingPanel is gone, the two logic changes are unit-tested (28 tests), and the integration is build-verified + manually checked. Use **superpowers:finishing-a-development-branch** to merge.

Follow-ups explicitly out of v1 scope (spec §Out of scope): new AI capabilities, ambient/proactive status, UI polish of the dropdown, external-display rendering, hover hook if 1.1.0 lacks one.
