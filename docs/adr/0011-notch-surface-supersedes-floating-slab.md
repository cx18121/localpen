# ADR 0011 — The assistant surface lives in the MacBook notch, superseding the floating slab

**Status:** Accepted
**Date:** 2026-05-27
**Supersedes:** the *presentation* decision in [ADR 0001](./0001-phase-1-quick-action-only.md) (the right-edge floating `NSPanel` "slab"). ADR 0001's scoping decision (quick-action first, conversation in 1.5) still stands — only where the surface lives changes.

## Context

Phase 1 / 1.5 shipped the assistant as a hotkey-summoned right-edge floating slab (`FloatingPanel`). The product direction is for Localpen to become a full AI assistant that lives in the MacBook notch (Dynamic-Island-style): persistent-but-calm at rest, expanding on demand. v1 of that move **ports the existing text-editing (quick actions + conversation) into the notch surface** — no new AI capabilities yet.

The state machine, capture, streaming, conversation, and persistence are unchanged. Only the presentation layer and invocation change.

## Decision

**The assistant surface is a single notch-anchored window built on DynamicNotchKit** ([ADR 0008 amendment](./0008-keyboardshortcuts-instead-of-masshortcut.md)). `FloatingPanel` is retired.

- **Idle = `compact()`**, not `hide()` — a faint accent dot (`NotchDot`) rests at the notch. The window stays alive so hover/click work. `hide()` is only used on app teardown.
- **Invocation:** the existing hotkey (⌃⌥Space) AND pointer — **hover-after-dwell (~0.4s) and click** on the resting notch. Hotkey opens with capture (pasteable session); hover/click opens with no capture (non-pasteable session — accept copies to clipboard rather than pasting into the frontmost app).
- **Capture ordering:** the hotkey path captures the selection *before* expanding the interactive surface (reverting the slab's show-first "snappy open"), because an interactive notch presented during the synthetic-copy wait races focus and risks capturing from / pasting into the wrong app.
- **Keyboard:** a responder-aware local key monitor **scoped to the notch window** routes shortcuts to the controller only when no text editor owns the key, preserving `GrowingTextEditor`'s Esc-to-blur in the input editor and reproducing the old `FloatingPanel.cancelOperation` Escape-out-of-submit-editor behavior.
- **Display:** `NotchPresenter` explicitly targets the built-in notched display (`NSScreen.notched()`), so on a docked MacBook the surface doesn't land on an external monitor or fall back to the floating style.

The seam is `NotchPresenter` — `PanelController` calls `expand()` / `idle()` and never touches DynamicNotchKit directly.

## Alternatives considered

1. **Custom-rolled notch window.** Full control, but reimplements DynamicNotchKit's notch shape, insets, screen-parameter handling, and compact/expanded transitions — significant craft for no differentiation. Rejected.
2. **Two surfaces (keep the slab + add a notch launcher).** Rejected during brainstorm: two panels is conceptually muddier; the notch *is* the assistant.
3. **Keep the floating slab.** Rejected: the notch is the committed product direction; the slab was always the Phase 1 expedient.
4. **Hotkey-only v1, defer hover/click.** Considered; rejected by the user — build the full intended surface in one go rather than a deliberately-reduced v1.

## Consequences

- New SPM dependency: DynamicNotchKit (see ADR 0008 amendment). Fourth dependency.
- `FloatingPanel.swift` deleted; `PanelController`'s `showPanel`/`focusPanel`/`hidePanelAnimated`/`sidebarTopLeft`/`pinnedTopY` removed; presentation routes through `NotchPresenter`.
- `acceptResult` now honors `session.canPasteBack` (a non-pasteable hover/click result copies instead of pasting) — a small but real logic change, mirroring `acceptTurn`.
- Verification is build + manual visual check (the repo's view/AppKit posture); the logic layer's 22 tests still cover the unchanged core.
- Notched MacBooks only; external-display *rendering* is out of scope (the surface always shows on the built-in notched display).
