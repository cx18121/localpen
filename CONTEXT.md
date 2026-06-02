# Localpen — Context & Glossary

Domain language for Localpen. Update inline as terms get sharpened. Don't include implementation details here — only terms that are meaningful to product/domain conversations.

See also: [PRD.md](./PRD.md), [docs/adr/](./docs/adr/).

---

## Surfaces

The user-facing UI is a single `NSPanel`. It hosts two **surfaces**: the **quick-action surface** (the selection fast-path) and the **hub surface** (the no-selection home, added in the 2026-06-01 brain redesign). "Surface" is the canonical term for these two top-level interaction contexts.

The hub surface is internally divided into **modes** — Ask / KB / People / Capture / Now. "Mode" is the canonical term for a hub area as of 2026-06-01. (This supersedes the earlier rule that banned "mode"; the rename was a deliberate call when the hub was introduced.) The former standalone **conversational surface** is now the **Ask mode** of the hub — same persistent multi-turn behavior, now hosted inside the hub rather than as a separate top-level surface.

### Quick-action surface
The Phase 1 surface. Transient. Triggered by global hotkey while text is selected in any app. The panel appears with the captured selection and an action menu. The user picks an action; the model streams a result into the panel; the result pastes back into the source app; the panel dismisses.

Stateless across invocations — no conversation history, no follow-up turns. One shot. The latency target (<500ms hotkey-to-first-token) belongs to this surface.

### Conversational surface
The Phase 1.5 surface. Persistent. The same NSPanel stays open and accepts multi-turn input. Free-form chat over the selection. Proactive nudges ("this email reads tense — soften?"). Visible history.

Latency target does *not* apply here — what matters is response quality and coherence, not speed-to-first-token.

---

## Core operations

### Selection
The text the user has highlighted in the active app's text field, captured by synthetic ⌘C at hotkey time. The captured value lives on the system pasteboard briefly and is then read into the panel. The original pasteboard contents are saved beforehand and restored afterward. See [ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md).

### Paste-back
The operation that writes a model result back into the source app's text field. Implemented by writing the result to the pasteboard, re-activating the original frontmost app, posting synthetic ⌘V, and restoring the original pasteboard contents after the paste lands. No direct AX tree-walking. See [ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md).

### Action
A pre-defined transformation applied to the selection. The Phase 1 menu is six items: **Proofread**, **Polish**, **More formal**, **More casual**, **Shorter**, **Custom**. Each non-Custom action maps to a fixed system prompt with precise, predictable behavior. Custom takes a free-form user prompt. Translate is deferred to Phase 1.5+. See [ADR 0004](./docs/adr/0004-v1-action-set.md).

### Interaction
A single hotkey-to-accept cycle: selection → action → model output → accept-or-reject (with optional edit before accept). Every interaction is persisted to local SQLite from Phase 1, ready for Phase 2's memory inference. See [ADR 0006](./docs/adr/0006-persist-interactions-from-day-1.md).

---

## Context

Material the assistant reads to ground an Ask, beyond the question itself. Two distinct kinds, split by *when* they're read — they are **not** one thing (see [ADR 0019](./docs/adr/0019-context-source-seam.md)):

### Context source
An **ambient, query-independent** input read at **capture time** (the moment you invoke Localpen), frozen for the session, and shown as a **removable chip** above the Ask input. "What's around you right now": the **active app/window**, your **calendar**, the **file you have open**, what's **on your screen**, your **mail**. Each is off by default, enabled from Settings, and gated by its own authorization. The canonical term for one such input is a **context source**; the captured value it contributes is a **context item**.

### Knowledge (brain context)
A **query-dependent, relevance-ranked** input read at **stream time** (it needs your question to rank against), drawn from the knowledge brain and shown as **provenance** under the answer, not as a pre-filled chip. This is the brain ([ADR 0014](./docs/adr/0014-brain-derived-fts5-index-over-vault.md)) and is deliberately **not** a context source — different timing, different surfacing, different mechanism.

The **selection** (above) is neither: it is the *operand* a transform acts on, not ambient context.
