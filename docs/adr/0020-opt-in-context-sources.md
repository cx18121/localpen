# ADR 0020 — Capture-time context is opt-in per ask, not always-on

**Status:** Accepted
**Date:** 2026-06-02
**Supersedes:** the "always-on once enabled" attachment model of [ADR 0012](./0012-calendar-readonly-askcontext-chip.md) and [ADR 0019](./0019-context-source-seam.md). The *seam* (ADR 0019: one `ContextSource` family, one chip pipeline, one prompt loop, v8 persistence) stands; only *when context attaches* changes.

## Context

ADR 0012 established that an enabled capture-time source (calendar) attaches to **every** ask automatically, with a per-ask removable chip (opt-out). ADR 0019 generalized that to a family (files, mail, screen) on the same always-on terms.

In use this is backwards. Most asks ("rewrite this", "what's the regex for…") need none of your ambient context, so always-on means:

- **Noise** — irrelevant mail/schedule dilutes the prompt and can degrade the answer.
- **Privacy** — with mail enabled, message bodies land in *every* prompt by default; worse, the store is *read* (a ~80ms `.emlx` scan) on every notch-open even when the ask never uses it.
- **Wrong-way friction** — the common case (no context) requires manual removal each time; the rare case (wanted context) should be the one that takes an action.

The knowledge brain ([ADR 0014](./0014-brain-derived-fts5-index-over-vault.md)) is exempt: it's query-time and relevance-ranked, so it self-gates and stays automatic. This decision is only about the **capture-time** family.

## Decision

**Capture-time context sources are opt-in per ask.** Nothing ambient attaches by default; the user adds the source(s) they want for that ask from an **"add context" tray**, and only attached sources enter the prompt (and persist).

- **Lazy capture.** At summon Localpen captures only the cheap, frontmost-dependent context it *must* read while the user's app is still frontmost — the frontmost **pid** and the **selection** (the operand). It does **not** read mail, the open document, or the calendar feed. Each source is captured **only when added** (`addAskSource(kind)`), so an ask that adds nothing reads nothing. This fixes the privacy and per-summon-cost problems at the root, not just the prompt-pollution one.
- **The frontmost constraint drives the design.** Files (the open document) and any future frontmost-derived source depend on the app that was frontmost at summon — once the notch opens, Localpen is frontmost. So the summon pid is held and passed to a deferred Files capture. Calendar and Mail don't depend on the frontmost app, so they're captured fresh at add-time with no held state.
- **The tray** lists the sources that are *available* (enabled in Settings) and *not yet attached*. Adding runs that source's capture; the result becomes a normal removable chip (the existing chip rail). Removing a chip returns it to the tray.
- **Settings toggles now gate availability, not attachment** — "Mail is available to add as context," not "Mail rides every ask." Off ⇒ absent from the tray.
- **Persistence + resume unchanged** (v8 `context_sources`): only *attached* sources were ever in the prompt, so only they persist; a resumed thread replays its attached chips.
- **A fast submit awaits any in-flight add** (the calendar-attach await pattern, repurposed) so adding a source then immediately pressing return can't stream the ask before that source's capture lands.

The brain stays auto.

## Alternatives considered

- **Keep always-on, manual remove.** The status quo. Rejected by the user: noise + per-prompt privacy cost + wrong-way friction.
- **Stage everything at summon, attach on add.** Capture all enabled sources up front, tray just moves them attached. Simpler add path, but keeps the wasteful + privacy-unfriendly per-summon mail/file *read* even when unused. Rejected: lazy capture is barely more code (one held pid + a per-kind add switch) and removes the read entirely.
- **Smart heuristic auto-attach** (infer from the question). Rejected: surprising and unreliable, and still leaks when the guess is wrong.

## Consequences

- The hotkey `.ask` path no longer auto-attaches app/calendar/sources; `AskContext.from(snapshot)` carries only the selection. The `ContextProbe.capture()` path drops its calendar + source reads (now on-demand), shrinking the hot path.
- The app/window "summoned-from" chip is dropped from free-form ask (low value, and it was the least useful auto-context). It can return as a tray source later if wanted.
- New surface: `PanelController.availableAskSources` + `addAskSource(_:)`; `AskInput` gains an add-context tray. Source-level capture (Files/Mail) is unchanged.
- A future frontmost-derived source must capture at summon (or via the held pid), not at add-time — noted here so it isn't re-litigated.
