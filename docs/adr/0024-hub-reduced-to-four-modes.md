# ADR 0024 — Hub reduced to four modes (Today · Ask · Notes · People)

**Status:** Accepted
**Date:** 2026-06-17
**Supersedes:** the *mode set* of [ADR 0016](./0016-hub-surface-and-modes.md). ADR 0016's surface taxonomy (two surfaces; the hub has "modes"; no-selection → hub) **still stands** — this ADR only changes which modes exist and how the thin ones are presented.

## Context

The hub grew to **seven** peer modes: Today, Ask, KB, People, Capture, Now, Suggestions. Three of them are thin or duplicative:

- **Now** renders `now.md` read-only — a whole tab for "show one file you can't edit here."
- **Capture** is a single write-to-inbox field.
- **Suggestions** is a low-frequency review queue (the nightly curation pass).

And **Today** is a roll-up that re-shows slices of three other modes: its Follow-ups duplicate **People**, its Now excerpt duplicates **Now**, its Inbox duplicates **Capture**'s target. So seven peer tabs sit in a 400 pt strip, several overlapping — directly against the product's own anchors (Raycast tightness, Things 3 breathing room, "calm operator", anti-ref "too AI app", [PRODUCT.md](../../PRODUCT.md)). The interface reads cluttered because it *is* redundant, not because spacing is wrong.

## Decision

**Four modes: `Today · Ask · Notes · People`.** Hub-and-spoke, not seven peers.

- **Today is the home glance** and absorbs the three thin modes:
  - **Now** → a "Focus" glance inside Today (the `now.md` excerpt + an "Open in editor" door). No standalone tab.
  - **Capture** → a quick single-line "jot to inbox" affordance at the top of Today. No standalone tab.
  - **Suggestions** → a "To review (N)" section in Today with inline Apply/Dismiss. Hidden when the queue is empty.
- **People stays** as the browsable CRM destination. **Today stops duplicating it**: Today shows follow-ups-due as a teaser that taps through to People, not the full list.
- **KB is renamed "Notes"** (plainer; "Knowledge" read as jargon).
- **Ask** is unchanged (the W2 grounded write/ask surface).
- Today's sections **hide when empty** and get **generous inter-section spacing** (the old Today used `spacing: 0`, jamming four section headers together — a primary cause of the cluttered feel).

`HubModel`'s data loaders (`loadNow`, `loadSuggestions`, `commitCapture`, `applySuggestion`, `dismissSuggestion`) are **kept** — their content now renders inside Today instead of standalone views. The `NowModeView`, `CaptureModeView`, and `SuggestionsModeView` files are deleted.

A persisted last-mode of `now`/`capture`/`suggestions` decodes to `nil` and falls back to `ask` — safe, no migration.

## Consequences

- The mode strip drops from 7 tiles to 4: tighter top chrome, closer to the Raycast/Granola form the product commits to.
- Today does more but reads calmer: one scannable column, empty sections hidden, real breathing room, each item one tap to its full surface.
- Suggestions and quick-capture lose a dedicated tab but gain context (they live where you already glance each day).
- Loss: Capture is now a one-line field, not a multi-line editor. Acceptable — inbox jots are short; longer notes belong in Obsidian.

## Alternatives considered

- **Minimal, 3 tabs (Today · Ask · Notes), People folded too.** Rejected: People is a genuine browsable destination (full contact list + reconnect), not a glance; folding it makes browsing contacts a Today detour.
- **Keep 7, only distill spacing.** Rejected: spacing can't fix duplication. Today competing with People/Now/Capture is structural.
- **Drop Today, keep the spokes.** Rejected: the daily glance is the highest-value read; the spokes are the duplicators.
