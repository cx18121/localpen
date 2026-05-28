# Localpen — Long-term Roadmap

> The live north star and build sequence. For *why the project exists* and the original market
> analysis, see [PRD.md](./PRD.md) — but note that the PRD's target-user phasing, competitive
> wedge, and distribution narrative are **historical**: Localpen is now a solo tool, built
> features-first, not shipped to others. This file supersedes the PRD's "Phasing" section.

**Date:** 2026-05-27

---

## North star

A notch-resident **local personal assistant**. Writing is the entry point — already built and
polished (quick-action + conversation surfaces, now living in the MacBook notch via
[ADR 0011](./docs/adr/0011-notch-surface-supersedes-floating-slab.md)). The destination is
something you can ask anything, that pulls in your context and acts on your behalf — entirely
on-device, no cloud.

The arc is **selection-transformer → assistant**: today Localpen rewrites text you've selected;
long-term it answers free-form requests grounded in your voice, your files, your calendar, your
mail — and eventually does things with them.

## Capability ladder

How far "acts on your behalf" goes. We climb one rung at a time; each rung is a deliberate
decision, not an accident.

1. **Read + draft, never send** ← *where we are headed first.* Pulls context to inform what it
   writes or tells you, and drafts actions, but a human always does the final send / commit. No
   irreversible action taken without a person. This is the natural extension of the existing
   clipboard paste-back model: Localpen prepares, you confirm by pasting.
2. **Act with confirmation.** Real side effects (send mail, create a calendar event, move a file)
   behind a one-click approval gate that shows exactly what will happen.
3. **Act autonomously.** Trusted, low-risk actions only, no prompt. Aspirational — gated on rung 2
   proving reliable.

## Build sequence

Dependency spine is **A → B → C → D**. E and F are independent and opportunistic.

| # | Sub-project | What it is | Rung |
|---|---|---|---|
| **A** | **Memory** *(next)* | Local store of your writing voice + personal facts, inferred implicitly from persisted interactions and injected into every prompt. No memory-management UI. | 1 |
| **B** | **Free-form ask + context intake** | The pivot: the notch stops being a selection-transformer and becomes something you ask anything. Pulls cheap context first — current selection, active app, on-screen text. | 1 |
| **C** | **Read-only integrations** | Calendar (EventKit), Mail, Files, screen-OCR as context *sources*. Read-only first to contain blast radius. | 1 |
| **D** | **Tool-calling architecture** | The framework that lets the model choose which source to read / action to draft. The gate to graduate from rung 1 to rung 2. | 1 → 2 |
| **E** | **Personalities** | Curated personas, per-conversation switching. Partly subsumed by A + system prompts; lower priority given the assistant focus. | — |
| **F** | **Voice input** | Wispr-style dictation into the notch. Architecturally independent — can land anytime. | — |

Each sub-project gets its own design spec → implementation plan → build. This table is the map,
not a schedule.

## What stays true

Commitments that survive the reframe — do not relitigate without an ADR:

- **Local-only, no cloud.** ([PRD principle 4](./PRD.md))
- **Clipboard-mediated I/O, no AX-tree-walking.** ([ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md)) — the assistant reads context through deliberate, scoped sources (B/C), not by walking every app's accessibility tree.
- **Model-agnostic.** ([ADR 0005](./docs/adr/0005-model-agnostic-architecture.md)) — Qwen 2.5 7B is the soft default.
- **Persist every interaction.** ([ADR 0006](./docs/adr/0006-persist-interactions-from-day-1.md)) — this is precisely what makes **implicit memory (A)** possible without a separate capture step.

## Open risks

- **Local-model tool-calling reliability (rung 2 / sub-project D).** Qwen 2.5 7B supports
  tool-calling but is not frontier-class at it. Reaching reliable confirm-gated actions may push
  toward a more tool-capable local model — permitted under ADR 0005, but a real selection
  pressure to name now.
- **Integration surface area (C).** Each context source (mail, calendar, files) is genuine
  complexity and permission scope. Read-only first keeps the blast radius small; writing actions
  wait for rung 2.
- **Scope creep away from writing.** The writing core is what's excellent today. Each assistant
  step must not regress the thing that already works — memory (A) is chosen first precisely
  because it *improves* the writing tool while laying assistant groundwork.
