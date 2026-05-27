# Notch Assistant — Design (v1)

**Status:** Revised after adversarial design review (2026-05-27). Capture-ordering, invocation-contract, keyboard-routing, and display-targeting invariants now explicit. Ready for implementation planning.
**Date:** 2026-05-27
**Reframes:** ADR 0001 (Phase 1 "floating slab") — the panel's home moves to the MacBook notch. **Vision:** Localpen becomes a full AI assistant living in the notch; **v1 ports only the existing text-editing** (quick actions + conversation) into the notch surface. No new AI capabilities in v1.

## Goal

Move Localpen's UI from a hotkey-summoned right-edge slab to a **single notch-anchored surface** that drops down from the MacBook notch — invokable by the existing hotkey and by hover/click — reusing all of the existing Phase 1/1.5 behavior. Built on DynamicNotchKit so the notch shape/insets/positioning are handled for us.

## Locked decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Surface model | **One notch-anchored surface** (not two panels, not a launcher). The notch *is* the assistant; quick actions + conversation + history all expand from it. |
| Invoke | The existing **hotkey** (⌃⌥Space) AND **hover/click** on the notch. Hotkey remains the fast path. The two paths produce **different session contracts** — see "Invocation contracts" below; they are not interchangeable. |
| Idle state | **Persistent but calm** — at rest it reads as the bare hardware notch (DynamicNotchKit's collapsed state); an **optional faint accent status dot** is the only "alive" tell. No extra menu-bar chrome. |
| Build | **DynamicNotchKit** (MIT, macOS 13+, hosts arbitrary interactive SwiftUI) handles positioning, the seamless notch shape, insets, and expand/collapse. We supply our SwiftUI content. |
| Content | **Reuse `PanelView`** inside the notch rather than rebuilding — it already renders every `PanelState` phase. |
| Platform | **Notched MacBooks only.** Single user, single machine; DynamicNotchKit's non-notch floating fallback is acceptable-but-unused. `NotchPresenter` **explicitly targets the built-in notched display** (not `NSScreen.screens[0]`) — see "Display targeting" below. |
| De-risking | **Spike first** — prove keyboard input + selection capture work through DynamicNotchKit before porting the full UI. |

## Architecture

### New dependency
Add **DynamicNotchKit** (`https://github.com/MrKai77/DynamicNotchKit`, from 1.1.0). Requires:
- An ADR amending **0008** (SPM deps: was 3, now +DynamicNotchKit) with rationale.
- An ADR amending **0001** (the Phase 1 "floating slab" presentation is superseded by the notch surface).

### Presentation layer swap (`PanelController`)
The state machine, streaming, conversation, and persistence are **unchanged**. Capture **ordering and session contracts change** (see below) — the swap is not purely presentational. Presentation changes:
- **Remove/retire:** `FloatingPanel`, `showPanel`/`showPanel(makeKey:)`, `focusPanel`, `hidePanelAnimated`, `sidebarTopLeft`, `pinnedTopY`, `installObservers` (click-outside + mouse monitors may move/adapt).
- **Add:** a `DynamicNotch` instance hosting `PanelView(controller:)`. `expand()` replaces `showPanel`; `hide()` replaces `hidePanelAnimated`.

### Capture ordering (corrected invariant)
The original draft claimed "expand first without taking focus, then capture — as today." That is **wrong about today's behavior**: `captureAndShow()` *awaits* `textIO.captureSelection()` (which records the frontmost source app, then waits up to 600ms for the hotkey modifiers to lift before posting the synthetic ⌘C) **before** it ever shows the panel (`PanelController.swift:403-432`, `TextIO.swift:27-65`). Showing an *interactive* surface during that window is a focus race: if the user clicks or types in the notch during the modifier-wait, the synthetic ⌘C can land in Localpen while the saved source metadata still points at the original app, and a later revise/paste-back can write captured text into the wrong app.

**Invariant for the hotkey path:** capture completes against the real source app *before* any focusable/interactive surface appears. Two acceptable implementations, decided in the spike:
- **(a) Capture-then-present (matches today):** keep the hotkey path non-presenting until `captureSelection()` returns, then `expand()`. Simplest; loses the snappy-open "show instantly" feel.
- **(b) Non-interactive pre-capture state:** if we want the notch to visibly *open* before capture finishes, the pre-capture presentation must be strictly **non-focusable and non-interactive** (no first responder, no hit-testing) until capture returns, then promote to the interactive state and take key focus.

The snappy-open branch (`phase-1.5-followups`) flips to show-first; that ordering is **only safe under (b)**. The spike must prove whichever option we pick holds capture/paste-back targeting under adversarial input.

### Invocation contracts (hotkey vs hover/click)
The state machine assumes a live `PanelSession` with a real `capture`; generation requires `current` to exist (`PanelController.swift:556-558`) and one-shot/turn accept calls `pasteBack` gated only by `session.canPasteBack` + the deny-list. A naive hover/click "empty state" entry breaks this:
- If hover shows `.empty` with no session, picking an action silently no-ops.
- If hover fabricates a default `PanelSession`, accept can synthesize ⌘V into whatever app is frontmost (`.empty` has no source app; `PasteBackDenyList.shouldSkip(nil)` is `false`).

**Contract:** hover/click creates an **explicit non-pasteable session** — reuse the existing pattern from `resumeThread` (`PanelController.swift:844-846`), which already synthesizes `PanelSession(... canPasteBack: false)` for exactly this "no source field" case. Accept for a non-pasteable session **copies to clipboard** (never pastes), which `acceptTurn` already honors (`PanelController.swift:794-800`) but **`acceptResult` does not** — `acceptResult`'s `.revise` branch (`PanelController.swift:308-321`) pastes unconditionally. So the one change required in the "unchanged" controller: **`acceptResult` must consult `session.canPasteBack`** and fall back to clipboard like `acceptTurn` does. This is a real (small) logic change, not presentation.

### `PanelView` reuse
`PanelView(controller:)` is hosted unchanged as DynamicNotch content. Layout may need width/centering adjustments for a centered notch dropdown (vs the right-edge slab), but no structural rewrite. Notch dropdown target width ≈ 460pt (from the prototype), grows downward.

### Keyboard routing (the work item — responder-aware, not just re-sourced)
This is **not** merely "change the event source." Today's keyboard behavior depends on **responder order**: when `GrowingTextEditor`'s NSTextView is first responder, ordinary editing keys (Up/Down to move the cursor, Return/Shift-Return, Tab) reach the text view and edit text; `FloatingPanel.cancelOperation` specially forwards Escape because the NSTextView would otherwise swallow it (`FloatingPanel.swift:48-65`, `GrowingTextEditor.swift:85-106`). `handleKeyDown` only sees keys the responder chain didn't consume.

A local `NSEvent` monitor that feeds `handleKeyDown` **before** responder dispatch would make `.empty`/`.captured` consume Up/Down/Return/Tab/Escape unconditionally (`PanelController.swift:166-188`) — so arrow-key cursor movement or Return inside the editor would fire menu nav instead of editing. That's a regression.

**Required design (decide concrete mechanism in the spike):**
- Panel shortcuts route to `handleKeyDown` **only when no text editor owns the command** — i.e. preserve "responder gets first crack, controller handles the remainder." Options: a `local` `NSEvent` monitor that returns the event unconsumed when the first responder is an `NSTextView` (letting AppKit dispatch it normally) and only consumes/forwards to `handleKeyDown` otherwise; or per-field SwiftUI `.onKeyPress` that explicitly yields editing keys.
- **Escape forwarding from a focused editor must be preserved** — the `cancelOperation` path (Esc dismisses/back even while the NSTextView is first responder) has to be reproduced under the new window, since DynamicNotchKit's window won't carry `FloatingPanel`'s override.

**Spike must cover, with an NSTextView as first responder:** cursor arrows, Return and Shift-Return, Tab, Escape, editing a result, and reply-box submission — not just the quiet menu-nav happy path.

### Invoke / dismiss / idle
- **Invoke (hotkey):** `HotkeyService.onFire` → **capture first, then expand** (or non-interactive-then-promote per option (b) above). Pasteable session, as today.
- **Invoke (hover/click):** expand into a **non-pasteable session** (the `resumeThread` contract) with empty working text. Accept copies to clipboard, never pastes.
- **Dismiss:** Esc / click-away / accept → `notch.hide()`. The click-away monitor adapts to the notch window.
- **Idle:** collapsed notch; optional faint accent dot (toggleable; defaults on) as the only resting indicator.

### Display targeting
The current panel opens on the display containing the cursor (`PanelController.swift:446-459`), which matters because capture starts in another app on whatever display the user is working on. DynamicNotchKit's `expand(on:)` defaults to `NSScreen.screens[0]` and picks notch-vs-floating from the supplied screen — so on a notched MacBook driving an external monitor it could appear on the wrong screen or in the floating fallback. **`NotchPresenter` must explicitly resolve and target the built-in notched display** (e.g. the `NSScreen` whose `safeAreaInsets.top > 0` / has a notch), not the default. Behavior when the source app is on an external display: the notch surface still appears on the built-in display (documented, accepted for v1). The spike includes a docked / multi-display invocation case.

## Integration unknowns → spike gate

The **first implementation task is a throwaway spike** (not the real port). Before the spike, **verify the exact DynamicNotchKit 1.1.0 API/source** actually used (the `DynamicNotch` init, `expand(on:)` signature, focus/activation behavior, and how it picks notch-vs-floating) — the design's assumptions about it must be confirmed against the pinned version, not docs.

The spike must prove, in isolation — and **adversarially, not just the happy path**:
1. **Responder-aware keyboard** — with an NSTextView first responder hosted in the notch: cursor arrows move the caret, Return/Shift-Return behave correctly, Tab does the intended thing, **Escape still dismisses** (the `cancelOperation` equivalent), and menu nav (↑↓/Return) works *only* when no editor owns the command. Result editing and reply-box submission both work.
2. **Capture under adversarial focus** — hotkey path: confirm the chosen ordering (capture-then-present, or non-interactive-then-promote) keeps the synthetic ⌘C landing in the **source app** even when the user clicks/types at the notch during the ≤600ms modifier-wait window; and paste-back targets the source app, not Localpen.
3. **No-source / hover entry** — a non-pasteable session's accept **copies** rather than pasting into the frontmost app.
4. **Display targeting** — docked/multi-display: the notch surface appears on the built-in notched display (not `screens[0]`, not the floating fallback).

If the spike shows DynamicNotchKit can't host a first-responder text field, can't present non-activating, or can't be pinned to the built-in display, we revisit the build approach (custom-roll) before sinking effort into the port. Only after the spike passes do we port `PanelView` and retire `FloatingPanel`.

## Components

- **`NotchPresenter`** (new) — wraps `DynamicNotch`, owns expand/hide, resolves and targets the **built-in notched display**, and owns the capture-ordering choice (capture-then-present, or non-interactive-then-promote). The single seam `PanelController` talks to (replaces direct `FloatingPanel` calls). Keeps DynamicNotchKit specifics out of `PanelController`.
- **`PanelController`** (modified) — presentation calls go through `NotchPresenter`; keyboard routing re-wired (responder-aware); **`acceptResult` gains a `canPasteBack` check** (the one logic change for hover/click no-source sessions). State machine / streaming / persistence otherwise unchanged.
- **`PanelView`** (reused, minor layout tweaks for centered dropdown).
- **Key event source** (new small unit) — **responder-aware** local `NSEvent` monitor (yields editing keys to a first-responder NSTextView; preserves Escape forwarding) translating remaining keys to `handleKeyDown`.
- **Retired:** `FloatingPanel.swift` and the anchor/show/hide methods on `PanelController`.

## Error handling
Unchanged from current behavior (streaming errors, paste-back fallback, persistence best-effort). The notch swap doesn't touch those paths. If DynamicNotchKit's expand fails, fall back to logging + no-op (the hotkey simply doesn't open), surfaced like the existing server-not-ready beep.

## Testing
- The logic layer (Conversation, ConversationStore, prompts, streaming body, migration) stays covered by the existing 22 tests — the notch swap doesn't touch it.
- The notch presentation is **build-verified + manual visual check** (consistent with the repo's view/AppKit testing posture; no view tests).
- The **spike** is the verification for the integration unknowns (keyboard, capture) — a manual checklist, not an automated test.

## Out of scope (v1)

- Any **new AI-assistant capabilities** (the long-term vision) — v1 is a presentation move only.
- **Live ambient status / proactive surfacing** in the resting notch (beyond the optional dot).
- **UI/UX polish** of the notch dropdown (the prototype is rough; a polish pass is a later cycle).
- **Non-notch Mac** support, and **presenting on an external display** (the surface always appears on the built-in notched display per "Display targeting"; DynamicNotchKit's non-notch floating fallback exists but is unused/untargeted). Note: explicitly *targeting* the built-in display *is* in scope — what's out of scope is rendering anywhere else.
- Removing the hotkey (it stays — it's the fast invoke).

## ADR candidates (write during planning)
- Amend ADR 0008: add DynamicNotchKit dependency (rationale: notch shape/positioning craft).
- Amend/supersede ADR 0001: presentation surface = notch, not right-edge slab.
