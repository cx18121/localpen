# Localpen — Long-term Roadmap

> The live north star and build sequence. For *why the project exists* and the original market
> analysis, see [PRD.md](./PRD.md) — but note that the PRD's target-user phasing, competitive
> wedge, and distribution narrative are **historical**: Localpen is now a solo tool, built
> features-first, not shipped to others. This file supersedes the PRD's "Phasing" section.

**Date:** 2026-05-27 · **Narrowed 2026-06-06** ([ADR 0022](./docs/adr/0022-narrow-to-moat-writing-and-brain-complement-poke.md))

---

## North star

A notch-resident, fully-local **writing + knowledge tool** — the two things a cloud assistant
structurally can't do: reshape text *in your editor* on the Mac, and reason over a *private
on-device brain* of your own files. Cloud-free, summon-only, yours.

**Narrowed 2026-06-06 (ADR 0022).** The old arc — *selection-transformer → general assistant*
(ask-anything, acts-on-your-behalf, rung-2 tool-calling) — is **retired**. That destination is
occupied by Poke (the iMessage assistant): cloud, proactive, everywhere, frontier-model
tool-calling. Localpen would only ship a worse version. So Localpen **complements** Poke instead
of competing: **Poke = the in-the-world assistant; Localpen = the local writing + knowledge
tool.** Different lanes, no overlap.

The wedge is their **intersection**: writing in your editor, grounded in your private brain —
*"rewrite this reply using what I know about [[Ana]], in my voice."* Poke can reach neither your
editor nor your local vault. This is uniquely, durably Localpen's.

## Capability ladder

Localpen stays at **rung 1 — read + draft, never act — permanently, by choice.** It pulls context
to inform what it writes, and the human always does the final paste/commit. Rungs 2–3 (act with
confirmation / autonomously) are **dropped** (ADR 0022): acting in the world is Poke's lane.

## Build sequence

Shipped foundation: **A** (Memory/voice), **B** (free-form ask + context intake), **C**
(read-only context sources: Files, Calendar-ICS, Mail, screen-OCR), and the **Brain** (FTS5 over
cxkb + hub + dream-cycle curation). The old A→B→C→**D** spine ends at C — **D (tool-calling) and
E (personalities) are retired** (ADR 0022).

The narrowed roadmap deepens the moat — sequence **W1 → W2 → W3**:

| # | Workstream | What it is | Moat |
|---|---|---|---|
| **W1** | **Writing core, deepened** *(next)* | Inline diff / accept-reject before paste, voice-aware rewrite using the Memory profile, continue-writing/expand. The daily driver. W1's accept-reject view is the *trust mechanism* every rewrite needs — first by value and a prerequisite for W2. | in-editor writing |
| **W2** | **Brain-grounded writing** *(the wedge)* | Quick-action + ask surfaces pull cxkb context about the people/projects you mention; draft and reply grounded in your notes, in your voice. The intersection only Localpen can do. | writing × brain |
| **W3** | **Brain, deepened** | Retrieval quality, backlink/graph navigation, faster "ask my notes." Pulled forward only as far as W2's retrieval needs demand. | private brain |
| **F** | **Voice input** *(opportunistic)* | Wispr-style dictation into the writing surface. Independent; now *more* aligned with the narrowed frame. | — |

Each workstream gets its own design spec → implementation plan → build. This table is the map,
not a schedule.

## What stays true

Commitments that survive the narrowing — do not relitigate without an ADR:

- **Local-only, no cloud.** ([PRD principle 4](./PRD.md)) — now the *defining* differentiator, not just a principle.
- **Clipboard-mediated I/O, no AX-tree-walking.** ([ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md)) — context is read through deliberate, scoped sources (C), not by walking every app's accessibility tree.
- **Model-agnostic.** ([ADR 0005](./docs/adr/0005-model-agnostic-architecture.md)) — Qwen 2.5 7B is the soft default. (No longer pressured by tool-calling reliability, since tool-calling is dropped.)
- **Persist every interaction.** ([ADR 0006](./docs/adr/0006-persist-interactions-from-day-1.md)) — what makes implicit memory (A) and voice-aware rewrite (W1) possible without a separate capture step.

## Open risks

- **Will it actually get used?** The honest risk behind the narrowing: with Poke covering general
  assistance, Localpen earns its keep only if the writing core is genuinely *better in-context*
  than alternatives and the brain-grounded writing feels magic. W1 leads precisely because it
  sharpens the thing already reached for most.
- **Brain retrieval quality (W2/W3).** Brain-grounded writing is only as good as what retrieval
  surfaces about the mentioned people/projects. W3 exists to backstop W2 here.
