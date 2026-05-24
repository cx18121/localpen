# Localpen Code Review — M0–M6

> Read-only review. No fixes applied. All findings cite exact file:line.

---

## 1. Active Bug

### P0 symptom: `activeModel == nil` produces the reported first-run/download error, but the suspected TOML root cause is not supported by the present checkout

**Evidence**

- `Localpen/Services/ModelRegistry.swift:52` — loads bundled `models.toml`; on decode failure it leaves `models` empty and therefore `activeModel` nil.
- `Localpen/FirstRun/FirstRunCoordinator.swift:102` — treats a nil active model as "not installed."
- `Localpen/FirstRun/FirstRunCoordinator.swift:63` — emits exactly `downloadError("No active model configured")`.
- `Localpen/Resources/models.toml:5` — defines the installed model ID as `qwen-2.5-7b-instruct-q4-km`.
- The observed installed file is `~/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf`, matching `ModelRegistry.swift:36`.
- `Localpen.xcodeproj/project.pbxproj:334` — includes `models.toml` and `known-bad-paste-apps.toml` in the resources build phase; the existing Debug app bundle also contains both files.
- No `~/Library/Application Support/Localpen/models.toml` user override exists in the inspected environment, eliminating the override path at `ModelRegistry.swift:60` for this run.

**TOML concern**

`[[models]]` with subsequent `[models.prompts]` and `[models.sampling]` is valid TOML array-of-tables nesting. The resolved TOMLKit 0.6.0 source includes Codable tests for arrays of nested tables and decoder support for arrays containing table values. There is no evidence that inline tables are required here.

`known-bad-paste-apps.toml` uses `bundle_ids = []`. TOMLKit's array decoding path supports an empty unkeyed container, and `Localpen/Services/PasteBackDenyList.swift:15` correctly declares `[String]`. No defect was identified in that resource.

**Why it matters**

The exact symptom chain is real, but the alleged initiating defect is not present in the current source/resource state. Changing valid TOML syntax would be speculative and could conceal the actual runtime discrepancy.

**Minimal fix recommendation**

Do not convert the TOML tables to inline tables without a captured decode error. The minimal corrective step is to make registry-load failure user-visible in first-run state, preserving the decode error currently only logged at `ModelRegistry.swift:80`, and add a `ModelRegistry` parse test using the shipped `models.toml`. Once the failing runtime's concrete decoder/resource error is captured, fix that specific input or decoding mismatch.

### P1: first-run automatically begins a download despite the coordinator comment and ADR requiring an explicit click

**Evidence**

- `Localpen/FirstRun/FirstRunCoordinator.swift:49` — comment says not to auto-start downloads.
- `Localpen/FirstRun/ModelDownloadView.swift:66` — immediately invokes `onStart()` whenever the view appears with zero downloaded bytes.
- ADR 0002 requires a one-click model download prompt.

**Why it matters**

Any registry/install-detection problem is immediately converted into a misleading download failure screen, which is exactly the reported experience.

---

## 2. Architecture & Correctness

### P0: download completion uses `MainActor.assumeIsolated` from a URLSession delegate queue

**Evidence**

- `Localpen/Services/ModelDownloader.swift:33` — creates a `URLSession` delegate session with `delegateQueue: nil`.
- `Localpen/Services/ModelDownloader.swift:67` — declares `didFinishDownloadingTo` as `nonisolated`.
- `Localpen/Services/ModelDownloader.swift:71` — calls `MainActor.assumeIsolated { self.destination }`.

**Why it matters**

URLSession delegate callbacks are not guaranteed to run on the main actor. `assumeIsolated` is an invalid actor assertion here and can trap when a real model download finishes.

### P1: dismissing a captured interaction discards the user's original clipboard

**Evidence**

- `Localpen/Services/TextIO.swift:21` — saves all original pasteboard item data before synthetic copy.
- The only restoration call is after successful automatic paste-back at `Localpen/Services/TextIO.swift:72`.
- `Localpen/Panel/PanelController.swift:56` — dismisses without calling any clipboard restoration path.

**Why it matters**

Select text, open Localpen, then press Escape: the clipboard remains overwritten with the captured selection. This violates ADR 0003 and affects normal cancellation.

### P1: stream cancellation does not cancel the underlying network generation

**Evidence**

- `Localpen/Services/StreamingClient.swift:11` — returns an `AsyncThrowingStream` whose producer is an unstructured `Task`.
- It supplies no `onTermination` handler and retains no request task to cancel.
- `Localpen/Panel/PanelController.swift:272` — only cancels its consumer task.

**Why it matters**

Dismiss, retry, and watchdog timeout can stop UI consumption while llama-server continues generating and the URLSession producer continues reading. This wastes inference capacity and can overlap subsequent requests.

### P1: error retry loses the original selection

**Evidence**

- Error state stores only `PanelError`, not the previous `Selection`, in `Localpen/Models/PanelState.swift:12`.
- `currentSelection()` returns nil for `.error` at `Localpen/Panel/PanelController.swift:380`.
- Retry paths restart generation from the error state at `Localpen/Panel/PanelController.swift:149`.

**Why it matters**

After a timeout or server error, Retry generates from empty input rather than the text the user selected.

### P1: completed rejected results can be silently lost from history

**Evidence**

- A completed result is staged as `pendingInteraction` at `Localpen/Panel/PanelController.swift:328`.
- `backToMenu()` does not persist that rejected result at `Localpen/Panel/PanelController.swift:85`.
- Completing a later generation overwrites `pendingInteraction`.

**Why it matters**

"Try another," followed by another completed action, loses the first rejection. ADR 0006 explicitly requires rejected interactions for later preference learning.

### P1: hotkey and animation tasks permit stale completion callbacks to affect later state

**Evidence**

- While `captureSelection()` awaits its 120 ms delay, `toggleFromHotkey()` leaves state `.hidden` and allows another capture task at `Localpen/Panel/PanelController.swift:48`.
- `hidePanelAnimated` has no animation generation/token guard; its completion unconditionally calls `orderOut` and restores frame at `Localpen/Panel/PanelController.swift:231`.
- `acceptResult()` performs asynchronous paste-back before hiding at `Localpen/Panel/PanelController.swift:103`.

**Why it matters**

Rapid hotkey presses or dismiss/accept interactions can race captures, saved clipboard context, and panel hide completions.

### P1: server startup is not gated before panel actions, and fixed-port health checking can accept the wrong process

**Evidence**

- First-run completion marks the app usable before async server startup completes at `Localpen/AppDelegate.swift:81` and `Localpen/AppDelegate.swift:95`.
- Hotkey handling checks only first-run completion at `Localpen/AppDelegate.swift:113`.
- `Localpen/Services/LlamaServerController.swift:13` — always uses port `11434`.
- Its startup loop checks HTTP health before checking whether its own spawned process exited at `Localpen/Services/LlamaServerController.swift:56`.

**Why it matters**

An early action can fail while the model is still loading. If another service already responds successfully on port 11434, Localpen can mark its failed process as ready and send user text to the wrong local endpoint.

### P1: persistence failure silently disables an ADR-required behavior

**Evidence**

- `Localpen/AppDelegate.swift:22` — initializes `Persistence` using `try?`.
- `Localpen/Panel/PanelController.swift:365` — silently skips saves when persistence is nil.

**Why it matters**

The app can appear usable while saving no interactions, violating ADR 0006 without surfacing an error.

---

## 3. Spec Drift

### P1: model-agnostic configuration is only partially implemented

**Evidence**

- `Localpen/Models/ModelDescriptor.swift:5` — decodes context size, chat template, sampling values, and checksum.
- `Localpen/Services/LlamaServerController.swift:30` — hardcodes `--ctx-size 4096`.
- `Localpen/Services/StreamingClient.swift:10` — uses only a hardcoded/default temperature; `top_p` and repetition penalty are unused.
- No code verifies `sha256`.

**Why it matters**

ADR 0005 states that switching models must require config changes only. Current inference behavior remains model-specific in code.

### P1: model downloads are not resumable and are not integrity-checked

**Evidence**

- `Localpen/Services/ModelDownloader.swift:26` — deletes any prior `.partial` file at every new download.
- No resume-data handling exists.
- `Localpen/Resources/models.toml:10` — ships an empty checksum, and no verification path exists.

**Why it matters**

This contradicts `SWIFTUI-SPEC.md` and `PLAN.md` M4.6; interrupted multi-gigabyte downloads restart from zero, and corrupted downloads can be accepted.

### P2: keyboard behavior differs from the locked design

**Evidence**

- DESIGN §5.5 states hotkey re-press while open is a no-op; `Localpen/Panel/PanelController.swift:48` dismisses the panel.
- DESIGN §5.1 states Escape dismisses from any state; `Localpen/Panel/PanelController.swift:94` returns generating/result/error/custom states to the menu.
- DESIGN permits `⌘↩` during streaming; `Localpen/Panel/PanelController.swift:103` accepts only `.result`.

**Why it matters**

These are externally visible interaction changes without acknowledgement in the inspected design or ADR documents.

### P2: several specified panel affordances are absent

**Evidence**

- `Localpen/Panel/SelectionBlock.swift:17` — truncates captured text after four lines rather than using the specified scrollable selection area.
- No click-outside dismissal or panel context-menu implementation appears in `Panel/*`.
- `Localpen/Settings/ModelPickerView.swift:12` — displays models only; it does not select or trigger installation as specified.

**Why it matters**

These are functional UI omissions rather than styling differences.

---

## 4. Anti-Patterns & Code Smells

### P2: stale milestone comments describe implemented code as future work

**Evidence**

- `Localpen/Resources/models.toml:2` — says M3 will wire the registry, although it is already wired.
- `Localpen/Models/ActionPrompts.swift:3` — says prompts will move to TOML, although TOML prompts are already loaded.
- `Localpen/Settings/HotkeyRecorderView.swift:4` — says settings wiring lands in M4 although it is present.

**Why it matters**

These comments are misleading when diagnosing incomplete versus implemented behavior.

### P2: unused abstractions leave competing sources of state

**Evidence**

- `Localpen/Models/AppState.swift:7` — defines an unused active model ID and permission state.
- `Localpen/Models/HotkeyConfig.swift:4` — is unused while KeyboardShortcuts owns persisted bindings.

**Why it matters**

Future changes can mistakenly target dead state containers instead of live services.

### P2: strict-concurrency checking is configured too weakly to catch current isolation mistakes

**Evidence**

- `project.yml:48` — sets `SWIFT_STRICT_CONCURRENCY: minimal`.
- The invalid URLSession/MainActor boundary in `ModelDownloader` is consequently easy to miss.

**Why it matters**

The app relies heavily on `@MainActor`, delegate callbacks, and detached tasks; minimal checking leaves real lifecycle defects undiagnosed.

---

## 5. Things That Look Like They Work But Probably Won't

### Watchdog cancellation

The watchdog task itself is guarded adequately: cancellation of `Task.sleep` is ignored, followed by `Task.isCancelled` at `Localpen/Panel/PanelController.swift:289`, preventing a cancelled watchdog from emitting a timeout. The larger fault is that cancelling `streamingTask` does not terminate the underlying producer in `Localpen/Services/StreamingClient.swift:11`.

### Accept and hide ordering

`acceptResult()` keeps the current result UI onscreen while paste-back sleeps and posts input, then starts a dismiss animation at `Localpen/Panel/PanelController.swift:116`. A user action during that interval can change state before the old completion hides the panel. There is no in-flight accepting state or operation identity check.

### Dismiss animation completion

`hidePanelAnimated()` always calls `panel.orderOut(nil)` in its completion handler. It does not validate that the panel still represents the operation that started that animation. Repeated dismiss/show activity can therefore allow an old animation completion to hide newer content.

### Download cancellation

`cancelDownload()` only cancels the URLSession task at `Localpen/FirstRun/FirstRunCoordinator.swift:92`. The resulting cancellation error is caught as a download failure at line 86 rather than returning the user to a neutral selection/download state.

### Server retry

The UI offers retry for generation errors, but because `.error` discards selection context, retry is structurally incapable of repeating the failed request correctly.

---

## 6. What To Fix Before Adding Features

### P0

- Fix `ModelDownloader.didFinishDownloadingTo` actor isolation; real downloads can trap at completion (`ModelDownloader.swift:71`).
- Reproduce the reported nil-model state using runtime error output or a model-registry parsing test before changing the valid TOML format. Surface registry failures distinctly from missing downloads.

### P1

- Restore the saved clipboard on all dismiss/reject paths, not only after successful paste-back (`TextIO.swift:72`, `PanelController.swift:56`).
- Preserve selection/action context through errors and retries (`PanelState.swift:12`, `PanelController.swift:380`).
- Couple stream cancellation to the URLSession/llama-server request via `onTermination` in `StreamingClient.swift:11`.
- Serialize capture, accept, and panel animation operations to prevent stale callbacks changing newer state (`PanelController.swift:48`, `:103`, `:231`).
- Gate generation on server readiness; validate that the health-checking process PID matches the spawned PID (`LlamaServerController.swift:56`).
- Persist rejected completed outputs when the user chooses another action (`PanelController.swift:85`).
- Make persistence initialization failure visible (`AppDelegate.swift:22`).
- Wire model config into llama-server args and StreamingClient params; implement checksum verification and resumable download (`LlamaServerController.swift:30`, `StreamingClient.swift:10`, `ModelDownloader.swift:26`).
- Remove automatic model-download start (`ModelDownloadView.swift:66`) or explicitly revise ADR/design if auto-start is now intended.

### P2

- Align hotkey-repress, Escape, and streaming-accept behavior with the documented keyboard contract (`PanelController.swift:48`, `:94`, `:103`).
- Implement or explicitly defer scrolling selection, click-outside dismiss, context menu, and model selection/download affordances.
- Remove stale milestone comments (`models.toml:2`, `ActionPrompts.swift:3`, `HotkeyRecorderView.swift:4`) and unused `AppState`/`HotkeyConfig` scaffolding.
- Raise `SWIFT_STRICT_CONCURRENCY` to `complete` or at minimum `targeted` (`project.yml:48`) so actor boundary violations are caught at compile time.

---

## Priority Summary

**P0**
- Unsafe `MainActor.assumeIsolated` in `ModelDownloader.didFinishDownloadingTo` — can trap on real model downloads.
- Active nil-model symptom requires runtime-backed diagnosis (stderr capture, registry unit test) rather than a speculative TOML rewrite.

**P1**
- Clipboard loss on dismiss/reject.
- Broken retry context (selection discarded with error state).
- Ineffective stream cancellation (URLSession producer keeps running after task cancel).
- Panel-operation races (hotkey capture, accept, animation completions).
- Premature server use before llama-server is ready; unsafe port-conflict handling.
- Lost rejection persistence (ADR 0006 violated on "try another" flow).
- Silent persistence disablement on DB init failure.
- Incomplete model-agnostic wiring (hardcoded ctx-size, sampling params, no checksum, non-resumable download).
- Auto-download violates ADR 0002 one-click requirement.

**P2**
- Keyboard/interaction drift from DESIGN.md §5 without acknowledgement.
- Missing panel affordances (scrollable selection, click-outside, context menu, model picker install action).
- Stale milestone comments and unused state stubs.
- Weak concurrency checking (`SWIFT_STRICT_CONCURRENCY: minimal`).
