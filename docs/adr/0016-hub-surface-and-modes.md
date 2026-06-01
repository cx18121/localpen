# ADR 0016 — The hub surface and its modes (supersedes the two-staged-surface model)

**Status:** Accepted
**Date:** 2026-06-01
**Supersedes:** the surface taxonomy in [CONTEXT.md](../../CONTEXT.md) and the *presentation grouping* implied by [ADR 0011](./0011-notch-surface-supersedes-floating-slab.md). ADR 0011's notch-anchored window and `NotchPresenter` seam still stand — the hub renders *inside* that window. ADR 0011's quick-action behavior is untouched.

## Context

Localpen is being redesigned (2026-06-01 brain pivot) into a Raycast-style **hub** opened by one hotkey, exposing the user's brain and several work areas. Until now the panel hosted two *surfaces* (`CONTEXT.md`): the transient **quick-action surface** (selection → transform → paste-back) and the persistent **conversational surface** (multi-turn Ask). The redesign adds Knowledge / People / Capture / Now alongside Ask, and needs a coherent navigation model and vocabulary.

`CONTEXT.md` explicitly made "surface" canonical and **banned "mode."** Raycast's mental model — and the user's — is "modes." That naming rule is now in the way.

## Decision

**Two surfaces; the hub has modes.**

- **Surfaces (top-level interaction contexts):** `quick-action` (the selection fast-path, unchanged) and `hub` (the no-selection home).
- **The hub's navigable areas are "modes":** Ask / KB / People / Capture / Now. **"Mode" is now the canonical term** for a hub area — this **overrides the prior `CONTEXT.md` ban** (a deliberate rename, recorded there).
- **The former conversational surface is the Ask mode** — same persistent multi-turn behavior, now hosted inside the hub rather than as a separate top-level surface.
- **Routing:** selection + hotkey → quick-action surface (unchanged, latency-critical). **No selection + hotkey → the hub**, opened on its last-used mode (default Ask) — so the common case lands effectively in Ask, just inside the hub chrome. *(This supersedes the foundation synthesis draft, which had kept "no-selection → Ask directly"; the user chose the hub as the home.)*
- **Implementation: a flat `HubMode` enum, not a protocol.** Modes are already modeled as an enum (`PanelState.Phase` gains `case hub`); the set is closed (5); a Mode protocol would be a competing dispatch mechanism for no gain. Mode views are independent files following a convention (`init(controller:)`, component-only rendering, no nav state), reusing the existing component vocabulary (`MenuRow`, `SectionHeader`, `EmptyStateView`, `Card`).
- **Calendar chip:** redesigned to a **structured summary** ("N events today" + next-event), visually distinct (calendar SF Symbol, accent tokens), separate from the gray app/selection chips — the original complaint that kicked off the redesign.

## Alternatives considered

1. **Call the hub areas "panes," keep the "mode" ban.** Cleaner against the old glossary, but the user explicitly chose "modes" (Raycast's and his own mental model). Vocabulary should match how the user thinks; the ban was the thing to revise.
2. **Make each area its own surface (surface-switcher).** Rejected: dilutes what "surface" meant (it would jump from 2 to ~6) and muddies ADR 0011's notch-surface concept.
3. **No-selection → Ask directly (the synthesis draft).** Rejected by the user: the hub should be the home base, not a secondary screen. Mitigated by opening the hub on the Ask mode by default, preserving a near-one-keypress path to Ask.
4. **A Mode protocol for extensibility.** Rejected: the mode set is closed and small; an enum + a file convention is simpler (Simplicity First) and matches the existing `Phase` pattern.

## Consequences

- `CONTEXT.md` updated: two surfaces (quick-action, hub); "mode" canonical for hub areas; conversational surface → Ask mode (done 2026-06-01).
- `PanelState.Phase` gains `case hub`; `PanelController` gains hub state (`hubMode`, `hubQuery`, focus index) and mode loaders; `PanelView` dispatches `case .hub` to a `HubShell`.
- The conversational surface is no longer a separate top-level concept in code/UI — it's the Ask mode. Existing `AskInput` is reused verbatim as that mode's body.
- New view files under `Localpen/Panel/Hub/`; auto-discovered by `project.yml` directory globbing (`xcodegen generate` once after they land).
- Verification: pure-logic tests where they apply + build + manual visual check (hand to the user; no scripted hotkey driving, per the project's testing posture).
