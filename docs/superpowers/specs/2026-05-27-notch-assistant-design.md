# Notch Assistant — Design (v1)

**Status:** Approved (brainstorm complete), ready for implementation planning.
**Date:** 2026-05-27
**Reframes:** ADR 0001 (Phase 1 "floating slab") — the panel's home moves to the MacBook notch. **Vision:** Localpen becomes a full AI assistant living in the notch; **v1 ports only the existing text-editing** (quick actions + conversation) into the notch surface. No new AI capabilities in v1.

## Goal

Move Localpen's UI from a hotkey-summoned right-edge slab to a **single notch-anchored surface** that drops down from the MacBook notch — invokable by the existing hotkey and by hover/click — reusing all of the existing Phase 1/1.5 behavior. Built on DynamicNotchKit so the notch shape/insets/positioning are handled for us.

## Locked decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Surface model | **One notch-anchored surface** (not two panels, not a launcher). The notch *is* the assistant; quick actions + conversation + history all expand from it. |
| Invoke | The existing **hotkey** (⌃⌥Space) AND **hover/click** on the notch. Hotkey remains the fast path. |
| Idle state | **Persistent but calm** — at rest it reads as the bare hardware notch (DynamicNotchKit's collapsed state); an **optional faint accent status dot** is the only "alive" tell. No extra menu-bar chrome. |
| Build | **DynamicNotchKit** (MIT, macOS 13+, hosts arbitrary interactive SwiftUI) handles positioning, the seamless notch shape, insets, and expand/collapse. We supply our SwiftUI content. |
| Content | **Reuse `PanelView`** inside the notch rather than rebuilding — it already renders every `PanelState` phase. |
| Platform | **Notched MacBooks only.** Single user, single machine; DynamicNotchKit's non-notch floating fallback is acceptable-but-unused. |
| De-risking | **Spike first** — prove keyboard input + selection capture work through DynamicNotchKit before porting the full UI. |

## Architecture

### New dependency
Add **DynamicNotchKit** (`https://github.com/MrKai77/DynamicNotchKit`, from 1.1.0). Requires:
- An ADR amending **0008** (SPM deps: was 3, now +DynamicNotchKit) with rationale.
- An ADR amending **0001** (the Phase 1 "floating slab" presentation is superseded by the notch surface).

### Presentation layer swap (`PanelController`)
The state machine, capture, streaming, conversation, and persistence are **unchanged**. Only the *presentation* changes:
- **Remove/retire:** `FloatingPanel`, `showPanel`/`showPanel(makeKey:)`, `focusPanel`, `hidePanelAnimated`, `sidebarTopLeft`, `pinnedTopY`, `installObservers` (click-outside + mouse monitors may move/adapt).
- **Add:** a `DynamicNotch` instance hosting `PanelView(controller:)`. `expand()` replaces `showPanel`; `hide()` replaces `hidePanelAnimated`.
- The snappy-open principle carries over: **expand without stealing focus** so the capture ⌘C lands in the source app, then take key focus for typing.

### `PanelView` reuse
`PanelView(controller:)` is hosted unchanged as DynamicNotch content. Layout may need width/centering adjustments for a centered notch dropdown (vs the right-edge slab), but no structural rewrite. Notch dropdown target width ≈ 460pt (from the prototype), grows downward.

### Keyboard routing (the work item)
Today `FloatingPanel.keyDown → onKeyDown → PanelController.handleKeyDown` routes ↑↓ nav, Return, Tab, Esc, ⌘C. DynamicNotchKit owns its window, so the **event source changes** — re-source via a local `NSEvent` monitor (or SwiftUI key handling) feeding the **unchanged** `handleKeyDown` logic. `FloatingPanel.cancelOperation` (Esc-through-NSTextView) behavior must be preserved by the new routing.

### Invoke / dismiss / idle
- **Invoke:** `HotkeyService.onFire` → expand + capture (as today, capture preserved). Hover/click on the notch → expand (no capture; empty state).
- **Dismiss:** Esc / click-away / accept → `notch.hide()`. The click-away monitor adapts to the notch window.
- **Idle:** collapsed notch; optional faint accent dot (toggleable; defaults on) as the only resting indicator.

## The two integration unknowns → spike gate

The **first implementation task is a throwaway spike** (not the real port). It must prove, in isolation:
1. **Keyboard + typing** work through a DynamicNotchKit-hosted view (a button responds; a text field accepts input; Esc closes).
2. **Selection capture** still works: hotkey expands the notch *without* stealing focus from the source app, the synthetic ⌘C captures the selection, then the notch view takes key focus.

If the spike shows DynamicNotchKit can't host a first-responder text field or can't expand non-activating, we revisit the build approach (custom-roll) before sinking effort into the port. Only after the spike passes do we port `PanelView` and retire `FloatingPanel`.

## Components

- **`NotchPresenter`** (new) — wraps `DynamicNotch`, owns expand/hide and the non-activating-then-focus dance; the single seam `PanelController` talks to (replaces direct `FloatingPanel` calls). Keeps DynamicNotchKit specifics out of `PanelController`.
- **`PanelController`** (modified) — presentation calls go through `NotchPresenter`; keyboard event source re-wired; capture/state/streaming unchanged.
- **`PanelView`** (reused, minor layout tweaks for centered dropdown).
- **Key event source** (new small unit) — local `NSEvent` monitor translating to `handleKeyDown`.
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
- **Non-notch Mac / external-display** support (DynamicNotchKit's fallback exists but is unused/untargeted).
- Removing the hotkey (it stays — it's the fast invoke).

## ADR candidates (write during planning)
- Amend ADR 0008: add DynamicNotchKit dependency (rationale: notch shape/positioning craft).
- Amend/supersede ADR 0001: presentation surface = notch, not right-edge slab.
