# ADR 0022 — Narrow to the moat: writing + brain, complement Poke (retire the assistant arc)

**Status:** Accepted
**Date:** 2026-06-06
**Related:** revises the **north star + capability ladder** in [ROADMAP.md](../../ROADMAP.md); shelves sub-project **D** (tool-calling) and drops rungs 2–3 of the capability ladder. Builds on the writing focus of [ADR 0001](./0001-phase-1-quick-action-surface-only.md) and the brain pivot ([ADR 0014](./0014-brain-derived-fts5-index-over-vault.md), [ADR 0016](./0016-hub-surface-and-modes.md)).

## Context

The ROADMAP arc was **selection-transformer → assistant**: keep climbing toward something you ask anything, that pulls your context and *acts on your behalf* (rung 2 = act with confirmation, via sub-project D's tool-calling).

That destination is now occupied. The user is already using **Poke** (the AI assistant in iMessage), and Poke wins the general-assistant lane *structurally*, not just by being further along:

- **It lives in iMessage** — zero new surface, on phone *and* Mac, always present. A notch app is Mac-only and summon-only.
- **It is proactive** — texts you first. Localpen is summon-only by design.
- **It is cloud** — frontier models, *reliable* tool-calling. The ROADMAP already names "local-model tool-calling reliability (Qwen-7B)" as the #1 open risk. Sub-project D is therefore months of fighting a reliability battle to ship a *worse* version of a capability the user already has.

Pursuing D means marching Localpen into Poke's strength on Poke's terms, with a hand tied behind its back. The honest conclusion: **Localpen-as-general-assistant has no reason to exist.**

But two capabilities are ones Poke **structurally cannot** provide:

1. **In-editor writing transformation on the Mac.** Select text in any app, reshape it in place. Poke is conversational in a chat window; it does not reach into your editor. (This is the original Localpen core — still excellent, still unique.)
2. **A fully-local, private brain over your own files.** The cxkb brain + dream-cycle curation runs on-device over your vault, cloud-free. Poke is not going to privately index your local Obsidian vault on your machine.

These are a real moat — not "we're behind," but "they can't go here." The sharpest point is their **intersection**: writing in your editor, grounded in your own knowledge ("rewrite this reply using what I know about [[Ana]], in my voice"). Poke can reach neither your editor nor your local brain, so this is uniquely, durably Localpen's.

## Decision

**Narrow Localpen to the two things Poke can't do — in-editor writing and the private local brain — and position it to *complement* Poke, not compete with it.**

- **Lanes:** Poke = the in-the-world assistant (does things, proactive, everywhere). Localpen = the local **writing + knowledge** tool (in your editor, over your vault, private). They do not overlap.
- **Out (retired):** tool-calling rung-2, send-actions, proactivity, calendar/mail *management* as actions. **Sub-project D is shelved.** Capability-ladder **rungs 2 and 3 are dropped** — Localpen stays at rung 1 (read + draft, the human acts), permanently, by choice.
- **In (new build sequence):**
  - **W1 — Writing core, deepened** *(daily driver)*: inline diff / accept-reject before paste, voice-aware rewrite using the Memory profile, continue-writing/expand.
  - **W2 — Brain-grounded writing** *(the wedge / intersection)*: quick-action + ask surfaces pull cxkb context about mentioned people/projects; draft and reply grounded in the vault, in the user's voice.
  - **W3 — Brain, deepened** *(moat 2)*: retrieval quality, backlink/graph navigation, faster "ask my notes"; pulled forward only as far as W2 needs.
- **Sequence W1 → W2 → W3.** W1's accept-reject/diff view is the *trust mechanism* every rewrite needs, including W2's brain-grounded ones — so it's first by value *and* a structural prerequisite.

## Alternatives considered

- **Build sub-project D anyway** (the prior roadmap). Rejected: redundant with Poke, and it spends the project's effort fighting local tool-calling reliability to produce a worse result than the user already has.
- **Wind Localpen down.** Rejected: the moat (in-editor writing + private brain) is real and *unserved* by Poke or anything else — there's a reason to exist, just not as a general assistant.
- **Keep competing as a general assistant.** Rejected: a structural loss on every axis (surface, proactivity, model quality).

## Consequences

- **ROADMAP.md north star + capability ladder + build sequence are rewritten** around W1/W2/W3; the A→B→C→**D** spine ends at C, with D/E retired.
- **Voice input (F)** stays opportunistic and is now *more* aligned — dictation into the writing surface fits the narrowed frame.
- **Commitments still hold and are reinforced:** local-only no-cloud ([principle 4](../../PRD.md)), clipboard-mediated I/O ([ADR 0003](./0003-clipboard-mediated-text-io.md)), persist every interaction ([ADR 0006](./0006-persist-interactions-from-day-1.md)). The read-only context sources (C) remain useful as *writing* context, not as a stepping stone to actions.
- The "scope creep away from writing" risk the old ROADMAP named is now resolved by fiat: writing (and the brain that feeds it) *is* the scope.
