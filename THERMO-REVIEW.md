# Localpen — Thermo-Nuclear Code Quality Audit

**Scope:** M0–M6 + Codex-review pass (`9666c7e`) + launch-bug hotfix (`908891a`).
**Lens:** maintainability / structure / spaghetti / code-judo. **Not** bug-hunting (REVIEW.md already covered that).
**Verdict:** *small, generally clean, but with one fat orchestrator that's the cause of most of the "buggy" feeling. The structural fixes below have very high leverage for a solo project.*

---

## TL;DR — what to actually do

In leverage order:

1. **Split `PanelController.swift` (433 LOC).** Extract a `PanelSession` type that owns one capture→generate→accept attempt. The `sessionID` integer scattered across six call-sites is the *visible* symptom of a missing abstraction. (Finding #1.)
2. **Make `pendingInteraction` a side-effect of state transitions, not a sibling property.** It is mutated in 6 places and forgetting to persist/clear it was *literally* the REVIEW.md "lost rejection" bug. (Finding #2.)
3. **Delete `ResultToolbar.actionPillLabel` (9 LOC). It is a verbatim duplicate of `Action.label`.** (Finding #6.) Free win.
4. **Replace `AppDelegate.observeFirstRunCompletion`'s 300ms polling loop with a closure callback from `FirstRunCoordinator`.** (Finding #4.) This is the only piece of code in the whole app that made me wince.
5. **Replace `AnchorStore`'s `[String:[String:[String:Double]]]` cast tower with a typed `Codable` model.** (Finding #8.) 4 LOC of types removes a "silent fallback hides decode failure" hazard.
6. **Simplify `ModelDownloader` (123 LOC of lock-guarded mutable state) to ~40 LOC of URLSession+continuation.** (Finding #11.) It is doing 3x what its job requires.

If you do only (1) and (2), most of "feels buggy" goes away — every bug in REVIEW.md §2 is downstream of *those two structural choices*.

---

## What is healthy and you can leave alone

I want a clear no-finding signal so you can trust the rest of the review.

- **`LocalpenApp.swift` (19 LOC)** — exactly the right size for a composition entry point.
- **`HotkeyService.swift` (25 LOC)** — clean wrapper around KeyboardShortcuts. Don't touch.
- **`FloatingPanel.swift` (29 LOC)** — pure subclass. No issues.
- **`StatusMenu.swift`, `PanelFooter.swift`, `ActionRow.swift`, `StreamingCaret.swift`, `ErrorBanner.swift`, `Hairline`** — leaf views. Each does one thing.
- **`DesignSystem/Tokens.swift`, `Spacing.swift`, `Typography.swift`, `Motion.swift`** — token registries. Naming is consistent. Don't refactor.
- **`Models/Selection.swift`, `Models/Interaction.swift`, `Models/Action.swift` (excepting #6), `Models/PanelError.swift`, `Models/PanelState.swift` (excepting #7)** — model types. Cleanly typed, no over-abstraction.
- **`Persistence.swift` (67 LOC)** — schema, migration, async save/count/deleteAll. Good. The only smell is the `try?` swallowing in AppDelegate's caller, not in Persistence itself.
- **`HardwareFingerprint.swift` (75 LOC)** — sysctl wrapper. The `JSONEncoder.iso8601` extension at the bottom (lines 68–75) is misplaced (it's a shared utility in a feature-specific file), but it has exactly one caller; just inline it. Minor.
- **`PermissionAskView.swift`, `ModelDownloadView.swift`, `FirstRunView.swift`** — first-run views. Modest size. Fine.
- **`HotkeyRecorderView.swift`** (10 LOC) — wrapper around KeyboardShortcuts.Recorder. Fine.
- **`ColorOKLCH.swift` (43 LOC)** — Björn Ottosson's algorithm with a thin `dynamic(light:dark:)` helper. The NSColor allocation on every access is theoretically wasteful but not a correctness or maintainability problem; flagged below as a minor item only because the rubric says to prefer "direct" code. Don't touch it unless you measure a render hit.

Everything else has at least one structural finding below.

---

## Findings, ranked

### 1. **STRUCTURAL** — `PanelController.swift` is doing six jobs in one file (433 LOC, the largest file)

**Where:** `Localpen/Panel/PanelController.swift:1-433`

The single class owns:

| Responsibility | Lines |
|---|---|
| State-machine API (`pick`, `submitCustomPrompt`, `backToMenu`, `handleEscape`, `acceptResult`, `setEditing`, `updateEditedResult`) | 77–162 |
| Hotkey/capture orchestration (`toggleFromHotkey`, `captureAndShow`) | 50–73, 213–234 |
| NSPanel show/hide animation, NSScreen anchor wiring, NSEvent global monitor | 236–312 |
| Streaming task + watchdog dance + retry policy | 314–340, 342–387, 166–209 |
| Persistence wiring (build, save, persist-rejected-if-needed) | 391–419 |
| Helper: state→selection extraction | 421–432 |

This is the *one* file that earned the "buggy" reputation — it's where REVIEW.md's race conditions, missing clipboard restores, and stale-callback issues live, because every async path has to remember to:

1. cancel `streamingTask` and `watchdogTask`
2. restore the clipboard if `activeCapture != nil`
3. persist `pendingInteraction` if non-nil
4. check `sessionID == mySession` to avoid overwriting newer state
5. clear `activeCapture`, `hotkeyTime`, `pendingInteraction`

The `sessionID` integer (`PanelController.swift:27, 65–67, 116–117, 137, 142, 188, 215, 220`) is the smoking gun. It appears six times as a "did the world move on?" check. The rubric calls this exactly: *a missing model, papered over with conditionals*.

**Code-judo move — `PanelSession`:**

```swift
@MainActor
final class PanelSession {
    let id: UInt64
    let capture: TextIO.Capture
    let hotkeyTime: ContinuousClock.Instant
    private(set) var streamingTask: Task<Void, Never>?
    private(set) var watchdogTask: Task<Void, Never>?
    var pendingInteraction: Interaction?

    func cancel() { streamingTask?.cancel(); watchdogTask?.cancel() }
}
```

PanelController would hold `private var current: PanelSession?` and *every* race check collapses to `guard session === self.current else { return }`. Every "is sessionID still mine?" check becomes one identity comparison. Every "is there still a capture to restore?" becomes `current?.capture` — there is no separate `activeCapture` property that can drift out of sync with `sessionID`.

The class would shrink to roughly:
- `PanelController` (~150 LOC) — pure state machine + view-bridge
- `PanelSession` (~80 LOC) — one attempt's data + tasks
- `PanelWindow` (~120 LOC) — NSPanel show/hide/animation/monitor (split from controller)
- `PanelStream` (~80 LOC) — runStream + armWatchdog moved here

That's a 4-way decomposition that gets PanelController below 200 LOC and gives each piece exactly one job. The behavioral surface stays identical.

---

### 2. **STRUCTURAL** — `pendingInteraction` is a property mutated across 6 call-sites and easy to forget

**Where:** `Localpen/Panel/PanelController.swift:26, 71, 97, 119–126, 193, 372–375, 415–419`

A completed-but-unaccepted result is stashed in `pendingInteraction`. Then *every* state-transition has to remember:

- `dismiss()` (line 71): clear it (but persistence is called via `persistRejectedIfNeeded` at line 58 — split across two helpers)
- `backToMenu()` (line 97): persist+clear
- `acceptResult()` (lines 119–126): mutate (set `accepted=true`) and persist
- `runStream` (lines 372–375): set it
- `retryFromError` (line 193): clear inside the `pasteBackFallback` branch, but NOT in the other branches — those go through `startGeneration` → `cancelStreaming` and rely on the next stream overwriting it

This *is* what REVIEW.md's "completed rejected results can be silently lost from history" bug is — `backToMenu` *now* persists, but the asymmetric handling across the 5+ transitions is structurally fragile and will reintroduce that bug whenever you add a 6th transition (Phase 1.5 conversational, retry-with-new-prompt, etc.).

**Code-judo move — persistence as an outcome of the state transition.** One of:

(a) `PanelState` mutations emit a `[SideEffect]` list (a small enum: `.persistRejected(Interaction)`, `.restoreClipboard`, `.cancelStreaming`). The controller's transition function returns these and a runner applies them. Forgetting becomes a compile error (enum exhaustiveness).

(b) Lighter: put `pendingInteraction` *inside* the `.result(...)` case of `PanelState` (it already holds selection/action/text/isEditing — add the interaction record). When leaving `.result`, the case's destructor pattern naturally surfaces what to persist. The signal "this result was rejected" becomes "we left `.result` without going through `acceptResult`".

Either way, the goal is: **you cannot leave `.result` without explicitly deciding what to do with the pending row**. The current code allows you to.

---

### 3. **STRUCTURAL** — `PanelView` is one step away from being a view-controller in disguise

**Where:** `Localpen/Panel/PanelView.swift:7-113`

Today the body is a 70-line `switch` over `PanelState` with inline view construction per case. At 151 LOC the file is fine, but two cases are notably heavier:

- `.generating` (lines 38–49): conditional `SelectionBlock`, `ResultView` in streaming mode, `ResultToolbar`
- `.result` (lines 51–73): all of the above + 3 callbacks + edit-mode branching

Each case is fundamentally a "screen". The fact that the switch fans out the view tree per case, *and then* `stateKey(_:)` (lines 116–126) re-runs the same switch to produce an animation key, is the duplicate-switch smell.

**Code-judo move:** extract a `View` per state:

```swift
case .generating(let sel, let action, let partial):
    GeneratingState(sel: sel, action: action, partial: partial)
case .result(let sel, let action, let text, let editing):
    ResultState(controller: controller, sel: sel, action: action, text: text, editing: editing)
```

Now `stateKey` can be replaced with `PanelState`'s own derived `Int` (move it onto the enum as `var renderKey: Int`). Both files shrink, the controller-view coupling clarifies, and you get cheap previewability per state.

This is a "do it when you next touch PanelView" change, not urgent.

---

### 4. **STRUCTURAL** — `AppDelegate.observeFirstRunCompletion` is a busy-wait polling loop

**Where:** `Localpen/AppDelegate.swift:92-102`

```swift
private func observeFirstRunCompletion() {
    Task { @MainActor in
        guard let coordinator = firstRunCoordinator else { return }
        while !coordinator.isComplete {
            try? await Task.sleep(for: .milliseconds(300))
        }
        firstRunWindow?.close()
        firstRunWindow = nil
        startServerIfNeeded()
    }
}
```

This polls an `@Observable` value at 300ms intervals. It works because `Observation` doesn't (easily) give you "wait until predicate". But this is the most jarring piece of code in the project: a deliberately-async system reduced to spin-wait.

**Code-judo move:** `FirstRunCoordinator` already has a single `step = .ready` write at line 89 of FirstRunCoordinator.swift. Make that a closure callback:

```swift
// In FirstRunCoordinator
var onComplete: (() -> Void)?
// in startDownload(), after step = .ready
onComplete?()
```

Or use AsyncStream if you want a more "Swift-y" handoff. Either way, kill the polling loop.

---

### 5. **STRUCTURAL** — `FirstRunCoordinator.evaluate()` has accumulating special-case branches

**Where:** `Localpen/FirstRun/FirstRunCoordinator.swift:43-56`

```swift
func evaluate() {
    if !isAXTrusted() { step = .permission; return }
    if !isModelInstalled() {
        // Don't auto-start: let the user click "Download" so it's explicit.
        if case .downloading = step { return }
        if case .downloadError = step { return }
        step = .downloading(bytesDone: 0, bytesTotal: ...)
        return
    }
    step = .ready
}
```

Those two `if case .downloading = step { return }` and `if case .downloadError = step { return }` lines are the rubric's "ad-hoc conditionals to paper over a state transition" smell. They exist because `evaluate()` is called both at init (correctly) AND from `NSApplication.didBecomeActiveNotification` (line 32) — which fires *during* a download (when the user toggles to System Settings to grant Accessibility), and re-entry would clobber the in-flight `.downloading(progress)` state.

**Code-judo move:** `evaluate()` should not be the same method called from app activation. Split:

- `evaluate()` — only safe to call when there is no active operation. Determines initial step at init time.
- `recheckPermission()` — only re-runs the AX probe; only transitions `.permission → other`, never the other direction. Bound to the activation observer.

Now neither method needs to know about other steps and the special-case branches disappear.

---

### 6. **CODE-JUDO / DEAD-DUPLICATION** — `ResultToolbar.actionPillLabel` duplicates `Action.label`

**Where:** `Localpen/Panel/ResultToolbar.swift:48-57`

```swift
private var actionPillLabel: String {
    switch action {
    case .proofread:   return "Proofread"
    case .polish:      return "Polish"
    case .moreFormal:  return "More formal"
    case .moreCasual:  return "More casual"
    case .shorter:     return "Shorter"
    case .custom:      return "Custom"   // only difference: no "…"
    }
}
```

`Action.label` (Action.swift:24-33) is verbatim the same minus the ellipsis on `.custom`. Replace with `action.label.replacingOccurrences(of: "…", with: "")` or add a `Action.pillLabel: String { label.trimmingCharacters(in: .punctuationCharacters) }`, or just expose two computed properties on `Action`.

This is a 9-line free deletion and removes the "if a 7th action gets added, will I remember to add it here too?" hazard.

---

### 7. **TYPE BOUNDARY** — `PanelState.ErrorContext` re-carries selection+action that the *non-error* cases already carry

**Where:** `Localpen/Models/PanelState.swift:11-19` and `PanelController.currentSelection()` `PanelController.swift:421-432`

The state stores selection in five cases directly (`.captured`, `.customPrompt`, `.generating`, `.result`) and one indirectly (`.error(_, prior: ErrorContext)`). `currentSelection()` then has to look in two places — directly inside the case, or inside `prior?.selection`. The asymmetry leaks: any future state that "wraps" another state would need its own envelope.

**Code-judo move:** make `PanelState` carry a *common* `PanelContext` struct (selection + active action) that all visible states share, then add a `phase` for what UI to show:

```swift
struct PanelState: Equatable {
    enum Phase: Equatable {
        case empty, captured, customPrompt
        case generating(partial: String)
        case result(text: String, editing: Bool)
        case error(PanelError)
    }
    let context: PanelContext  // selection + action (both optional)
    let phase: Phase
}
```

`currentSelection()` becomes `state.context.selection`. Retry-after-error becomes "construct a new state with the same context but a new phase". This is a bigger refactor than I'd normally suggest, but it removes a *category* of asymmetry-driven bugs. If you're touching the state machine for #1/#2 anyway, do this at the same time. Otherwise leave it.

---

### 8. **TYPE BOUNDARY** — `AnchorStore`'s nested `[String:[String:[String:Double]]]` cast

**Where:** `Localpen/Services/AnchorStore.swift:12-29`

```swift
if let bundleID, let screen,
   let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: [String: Double]]],
   let appDict = dict[bundleID],
   let stored = appDict[Self.displayID(for: screen)] {
    return NSPoint(x: stored["x"] ?? 0, y: stored["y"] ?? 0)
}
```

The rubric calls this verbatim: *"ad-hoc object shapes that obscure the real invariant"*. If any future schema migration changes the shape (e.g., you add the panel size to anchors), this cast silently fails and the user gets default placement forever — no logged error, no upgrade path.

**Code-judo move:** typed value with JSON encoding:

```swift
struct StoredAnchor: Codable { let x: Double; let y: Double }
typealias AnchorMap = [String: [String: StoredAnchor]]  // bundleID → displayID → anchor

func read(...) -> NSPoint {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
          let map = try? JSONDecoder().decode(AnchorMap.self, from: data),
          let stored = map[bundleID]?[displayID] else { return defaultPlacement(on: screen) }
    return NSPoint(x: stored.x, y: stored.y)
}
```

20 LOC instead of 30, no nested casts, no `?? 0` silent fallback. Schema bumps become a `Codable` migration not a silent miss.

---

### 9. **STRUCTURAL** — `runStream` is doing prompt-assembly + transport + first-token telemetry + state-mutation + error-classification in one function

**Where:** `Localpen/Panel/PanelController.swift:342-387`

The function:
- Builds the user prompt (special-cases `.custom`) — lines 343–351
- Arms a watchdog — line 353
- Pulls tokens — line 360
- Logs first-token latency — lines 362–366
- Re-arms watchdog on every token — line 369
- Builds the pending interaction — lines 372–375
- Sets state — line 376
- Classifies network error → `serverDown` vs `network` — lines 379–386

The "re-arm watchdog every token" pattern (line 369) is correct (you want a 30s no-token-progress watchdog, not a 30s total deadline). But it lives inside the streaming loop rather than as a `inactivityTimeout` on the AsyncStream itself.

The error classification at the bottom (NSURLErrorCannotConnectToHost → serverDown) is feature-specific logic in PanelController; it belongs in `StreamingClient` (which already knows about URLSession internals) or alongside the model in `PanelError`.

**Code-judo move:**
- Pull prompt assembly into a free function on `Action` (or `ActionPrompts.userMessage(for: action, text:)`).
- Pull error classification into `PanelError.init(_ error: Error)`.
- The remaining `runStream` is just the streaming loop + state mutation, ~20 LOC.

---

### 10. **MAGIC / NON-OBVIOUS** — `hidePanelAnimated` hops back to MainActor from an AppKit completion handler

**Where:** `Localpen/Panel/PanelController.swift:263-284`

```swift
NSAnimationContext.runAnimationGroup({ ctx in ... },
    completionHandler: {
        // Animation completion fires on the main thread but is typed as
        // nonisolated by the API. Hop to MainActor cleanly via Task.
        Task { @MainActor in
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrameOrigin(origin)
            completion?()
        }
    })
```

The comment is accurate but it's a code smell that you need a comment at all. Every `dismiss` / `acceptResult` schedules a Task that runs *some time later*, and the controller has no way to know if it's still relevant — which is REVIEW.md's "Dismiss animation completion" race.

**Code-judo move:** stop awaiting the animation completion *to mutate state*. The state goes to `.hidden` immediately when the user dismisses; the animation runs on its own and `orderOut` is a side-effect that's safe to apply unconditionally to whatever panel is currently shown (because re-show is `orderFrontRegardless` which is idempotent). Three-line version:

```swift
private func hidePanelAnimated() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.12; ...
        panel.animator().alphaValue = 0
    }) { panel.orderOut(nil) }  // safe regardless of session state
}
```

State transitions happen synchronously; UI catches up on its own. No more `mySession == sessionID` check in the completion handler.

---

### 11. **OVER-ENGINEERED** — `ModelDownloader` (123 LOC) is doing the work URLSession.shared.download(from:) already does

**Where:** `Localpen/Services/ModelDownloader.swift:1-123`

The class holds:
- `lock: NSLock`
- `destination: URL?`
- `partialURL: URL?`
- `session: URLSession?`
- `task: URLSessionDownloadTask?`
- `progressHandler: (@MainActor (Progress) -> Void)?`
- `continuation: CheckedContinuation<Void, Error>?`

…and implements three `URLSessionDownloadDelegate` callbacks with manual lock/unlock pairs around each property access. Five `lock.lock()` / `lock.unlock()` blocks in `download()` alone.

This delivers exactly what `URLSession.shared.download(from:delegate:)` (iOS 15 / macOS 12) + a simple `URLSessionTaskDelegate` for progress gives you. The whole class collapses to ~40 LOC. The remaining custom logic (atomic move from `.partial` to destination) is 3 LOC.

Caveat: the spec calls for resumable downloads (REVIEW.md §3 spec drift). Resumability *needs* the delegate path with `resumeData`. But the current code doesn't implement resumability either — it just kept the delegate scaffolding "in case". That's exactly the "future-proofing that's actually dead complexity" you asked me to flag.

**Recommendation:** delete the lock-guarded state machine. Either:
(a) Use `URLSession.shared.download(from:)` and live with non-resumable (matches current behavior).
(b) Implement actual resumability (catch `URLError`, extract `.userInfo[NSURLSessionDownloadTaskResumeData]`, store it).

Pick one. Don't keep the delegate boilerplate that buys you neither.

---

### 12. **MISPLACED CODE** — `HistoryDocument` is declared *after* a second `import` block inside `HistorySettingsView.swift`

**Where:** `Localpen/Settings/HistorySettingsView.swift:85-106`

```swift
// (end of HistorySettingsView struct)
}

import GRDB
import UniformTypeIdentifiers

struct HistoryDocument: FileDocument {
    ...
}
```

A second `import` block in the middle of a file is legal but extremely unusual and is a giveaway that two files were glued. Move `HistoryDocument` to its own file (`Settings/HistoryDocument.swift`) or to the top of this file with imports merged. While you're there: the `prepareExport` JSON encoding (lines 65–79) re-implements row→dictionary serialization manually; if `Interaction` is `Codable` (it is, via GRDB), just `try Interaction.fetchAll(db).map { try JSONEncoder().encode($0) }` and skip the dynamic-row-to-dict dance.

---

### 13. **STALE COMMENTS / DEAD HINTS** (minor)

You already cleaned up the big ones (REVIEW.md §4 — no `AppState.swift`, no `HotkeyConfig.swift`, no stale M3/M4 comments in `models.toml`). Remaining:

- `Localpen/Services/PasteBackDenyList.swift:6` — "Populated empirically during M7 manual testing." Accurate forward-looking note. Keep, but the M7 reference will go stale once M7 ships. Consider just removing the milestone tag.
- `Localpen/Models/ActionPrompts.swift:3-6` — comment is accurate now. Keep.
- `Localpen/Resources/models.toml:3-6` — the inline-table comment explaining the TOMLKit quirk is *load-bearing documentation*. Keep verbatim.

Nothing here is a blocker.

---

### 14. **SCAFFOLDING vs DEAD COMPLEXITY** (you asked me to call this out)

Searching for "future-proofing that's just dead complexity":

- **`ModelDownloader`'s delegate machinery** (finding #11) — *yes*, this is future-proofing for resumability you didn't ship. Delete or finish.
- **`PanelState.ErrorContext`** (finding #7) — *yes*, an extra envelope that exists to make selection-after-error survive, but the asymmetry creates more complexity than it removes. Rethink.
- **`ModelDescriptor.sampling`, `chatTemplate`, `contextSize`** — partly dead at the moment (REVIEW.md §3 noted ctx-size hardcoded, top_p/repeat_penalty wired but model.chat_template unused). After the Codex pass, `sampling` is now actually used in `StreamingClient.complete` (StreamingClient.swift:33–35). Good. `chat_template = "chatml"` is **still unused** in code — searched: no consumer. Either wire it (the spec implies llama-server takes a `--chat-template` arg) or drop the field from the TOML schema until you need it. Right now it's a config field with no effect.
- **`HardwareFingerprint`** persists a JSON snapshot that *nothing reads*. The comment at HardwareFingerprint.swift:5 says "Phase 2 auto-pick reads this; Phase 1 just collects." This is honest future-proofing — you've spec'd it explicitly. It's also 75 LOC of code for a feature that doesn't exist yet. Per project CLAUDE.md Rule 2 ("Nothing speculative"), this would normally be deleted. The redeeming feature is that `freeDiskBytes()` *is* used (FirstRunCoordinator.swift:71 for the disk-full pre-check). Keep `freeDiskBytes`, delete the full snapshot persistence (lines 18–30, 42–50). When Phase 2 needs it, write it then.
- **`MasShortcut` vs `KeyboardShortcuts` swap** — project CLAUDE.md still lists `MASShortcut` as the SPM dep but the code uses `KeyboardShortcuts` (HotkeyService.swift:2). Doc drift, not code rot, but worth a one-line CLAUDE.md fix.

---

### 15. **MINOR / NOTABLE** (cosmetic — only because nothing structural remains)

- **`ColorOKLCH.dynamic` allocates two NSColors per access** (ColorOKLCH.swift:16–23). Real impact is microseconds per render and the rubric explicitly says don't over-index on micro-perf. Leave it.
- **`PasteBackDenyList` parses TOML for a single `bundle_ids` array** (30 LOC) — a `static let bundleIDs: Set<String> = [...]` in Swift would be 5 LOC. TOML for a static list is overkill, but the file already exists and decoupling lets non-developers extend the list. Defensible. Keep.
- **`AnchorStore.panelSize: NSSize = ...` (AnchorStore.swift:10)** is unused (write/read store only x/y). Delete.

---

## What I am NOT flagging (and why)

- **The 6-action `switch` over `Action`** appears in 5 files (`Action.swift`, `ActionPrompts.swift`, `ModelRegistry.swift`, `ResultToolbar.swift`, `PanelController.swift`). The rubric would normally flag this as "missing model — should be a `case let action: ActionConfig` lookup". Don't refactor it. With 6 cases and clear exhaustiveness, the Swift compiler is doing your work for you — adding a 7th action will fail to compile in 5 places, which is *good*. The only real duplicate is #6 (ResultToolbar) which is literally Action.label.
- **`PanelView`'s `stateKey(_:)`** — flagged in #3, but the fix is "move it onto PanelState". Not a refactor on its own.
- **Async/await everywhere** — the project has thoughtful actor isolation (`@MainActor` on every controller/service that mutates UI-adjacent state). REVIEW.md flagged the strict-concurrency project setting; that's a setting fix, not a structural one.
- **No test surface** — flagged by REVIEW.md but out of scope for "code quality of what exists". You don't have tests; adding them is a separate decision.

---

## Approval (per the rubric)

**Would not approve as-is.** Two presumptive blockers from the rubric:

- **Spaghetti growth via ad-hoc conditionals** — the `sessionID == mySession` checks (Finding #1) and the `if case .downloading = step { return }` guards (Finding #5) are exactly what the rubric flags as "weird if-statements added to paper over a missing abstraction". The right fix is structural (extract `PanelSession`, split `evaluate`/`recheckPermission`), not more guards.
- **State mutated across many call-sites with no enforcement** — `pendingInteraction` (Finding #2) is the most concentrated example. The compiler can't help you here, and "remember to persist before clearing" is the kind of invariant that's structurally impossible to keep when async paths interleave.

Both are addressable in the existing architecture without adding new dependencies, new types beyond `PanelSession`, or any DI/test-container apparatus.

Everything else is improvement, not blocker. The codebase is small, the design tokens are clean, the model types are crisp. The single concentration of risk is `PanelController.swift` — fix that and the rest falls into place.
