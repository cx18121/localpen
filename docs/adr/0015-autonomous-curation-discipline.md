# ADR 0015 — Autonomous curation: judgment-split writes, dual local models, nightly dream cycle

**Status:** Accepted
**Date:** 2026-06-01
**Related:** writes into the vault that [ADR 0014](./0014-brain-derived-fts5-index-over-vault.md) indexes; honors the discuss-first discipline in `cxkb/CLAUDE.md`. This is a **later build phase** (Phase 4) — the read path (ADR 0014) and hub ([ADR 0016](./0016-hub-surface-and-modes.md)) ship first.

## Context

The user wants Localpen not just to *read* his knowledge base but to **help curate and synthesize it** — to get smarter while he sleeps (the GBrain "dream cycle" appeal). His instinct was "auto-curate everything, no gates."

Two hard constraints push back on naive auto-everything:

1. **The vault is human-curated by design.** `cxkb/CLAUDE.md` has discuss-first triggers precisely for the risky writes — substantial rewrites, topic promotion, contradictions — and explicitly forbids silently blending conflicting claims. An unsupervised model rewriting curated pages would degrade the very asset we're enriching.
2. **Model quality vs. local-only.** The product is local-only. The current default is Qwen 2.5 7B ([ADR 0005](./0005-model-agnostic-architecture.md)). A 7B doing *unsupervised* multi-document synthesis into a curated wiki is the real danger — it misattributes, blends contradictions, and you won't see the damage until later. The machine is a 24 GB M5 MacBook Air, which comfortably runs a ~14B model (a ~32B is tight; 70B won't fit).

The resolution had to keep it fully local and autonomous **without** letting a small model quietly mangle the best pages.

## Decision

**Fully local, autonomous curation — but writes are split by the *judgment* they require, not gated by per-write approval.**

- **Additive / structured writes → auto, no gates** (~90%): captures → `raw/inbox/`, appending a Timeline entry to an *existing* person, creating a source page from template, nominating dangling `[[links]]`, updating `now.md`. Mechanical; even 7B handles them; **git is the backstop**.
- **High-judgment writes → queued one-click suggestions** (~10%): rewriting a curated page, promoting a topic, resolving a contradiction, **creating a *new* person or merging/splitting identities**. This is a *competence boundary*, not an approval gate on the normal flow — the model isn't reliable enough to do these unsupervised, so it proposes and the user one-click applies (or hands that one page to a Claude Code session for a capable model).
- **Dual local model:** keep **Qwen-7B for the latency-critical quick-action transforms**; use a **~14B for curation/synthesis** writes where quality matters. Both local — ADR 0005 already permits model choice; this exercises it.
- **Hybrid cadence:** the ask hot path **stashes the raw conversation transcript** instantly (no synthesis, no latency). A **nightly "dream cycle"** (~14B, while the user sleeps) batch-synthesizes the day's conversations + `raw/inbox/` into additive writes + queued suggestions — one warm-up, not fifty.
- **Substance filter:** quick-action transforms *can* be filed, but only when the dream cycle's substance filter judges them brain-worthy (a draft to a named person about a project, yes; "fix this typo," no). The hot path files nothing.
- **Localpen operates under the vault's rules**, like the `/file-this` skill does — it is another agent honoring `cxkb/CLAUDE.md`, not a second curation engine that diverges from it.

## Alternatives considered

1. **Auto-apply everything, no gates (the user's first instinct).** Rejected: an unsupervised ≤14B rewriting curated pages degrades the wiki; the failure is invisible until it's filed. Kept the autonomy for the additive majority; queued only the error-prone minority.
2. **Propose-only — approve every write.** Rejected: high friction; even a capture would need a confirm. The judgment-split gives autonomy where it's safe.
3. **A capable cloud model (Claude API) for curation.** Rejected: breaks local-only, the product's core ethos. A ~14B local model is good enough for the additive bulk; high-judgment work is queued or handed to an on-demand Claude Code session — no standing cloud dependency.
4. **Keep 7B for everything.** Rejected for the curation path: 7B is the weak spot for multi-document synthesis; the Air can run a ~14B comfortably, so there's no reason to accept the quality floor.
5. **Per-conversation synthesis (no batch).** Rejected: adds 14B warm-up/latency after every conversation and processes throwaway asks. Batching nightly is cheaper and matches the "smarter while you sleep" goal.

## Consequences

- A ~14B instruct model must be downloaded and managed (RAM/disk) for the curation path — a second local model alongside the 7B.
- A scheduler runs the nightly dream cycle (the menu-bar app is always alive, so this is straightforward).
- A **suggestion queue** surfaces high-judgment proposals for one-click apply (a UI surface to design when this phase lands).
- This **deliberately overrides the vault's discuss-first gate for the additive class** — additive writes that previously wanted review now auto-apply, with git as the safety net. High-judgment writes still route through review (now as queued suggestions).
- People-graph population inherits this split: Timeline appends auto; new-person creation queued (avoids duplicate/garbled person pages from identity-resolution guesses).
- Scoped to a *later* phase; the read path and hub ship and prove out first.
