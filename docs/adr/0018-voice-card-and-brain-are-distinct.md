# ADR 0018 — Voice card and knowledge brain are distinct personalization layers

**Status:** Accepted
**Date:** 2026-06-02
**Related:** the voice/facts memory ([Memory sub-project A]) feeds prompts via `MemoryService.compose`; the knowledge brain ([ADR 0014](./0014-brain-derived-fts5-index-over-vault.md)) feeds prompts via the context engine. This ADR draws the line between them.

## Context

Two personalization mechanisms both inject context into the ask/transform prompt, built in different phases:

1. **`MemoryService` + `MemoryAttribution`** (Memory sub-project A): a SQLite-derived **voice card + facts** — a learned model of *how Charlie writes* (tone, length, phrasing) plus a few stable facts, composed into the system prompt by `MemoryService.compose`.
2. **The knowledge brain** ([ADR 0014](./0014-brain-derived-fts5-index-over-vault.md) + the curation pipeline): an FTS5 index over the `cxkb` vault — *what Charlie knows* — retrieved per-question and added as KB context.

After the brain pivot ([project memory: Localpen brain pivot]) the natural question is whether the older SQLite voice/facts path is now legacy — a parallel track the brain should subsume. A simplification review flagged the two as a possible coherence problem (two "memory" systems feeding the same prompt) and asked whether `MemoryService` (~450 lines) is a deletion candidate.

## Decision

**Keep both. They model different things and must not be merged.**

- **Voice card = *how* Charlie writes.** Derived from his own past edits/outputs (the `style_profile`), it shapes the *form* of a response. It is not knowledge; it has no place in the vault.
- **Brain = *what* Charlie knows.** Derived from the `cxkb` markdown vault, it supplies *facts/context* for a response. It is human-curated and git-backed.

The overlap is only that both append to the prompt. Their sources, lifecycles, storage, and privacy treatment differ:

| | Voice card (`MemoryService`) | Brain (ADR 0014) |
|---|---|---|
| Source | the user's own outputs/edits (SQLite `history`) | the `cxkb` vault (markdown) |
| Answers | *how* to write | *what* is true |
| Store | `style_profile` in `history.sqlite` | derived `brain.sqlite` FTS5 index |
| Curated by | inferred automatically | human + the dream cycle, under the vault's rules |

`MemoryService` and `MemoryAttribution` also do **not** overlap with each other: `MemoryAttribution` is a pure query-policy module (attribution + sample selection), `MemoryService` is the stateful orchestrator (cache, single-flight regeneration, gating, compose). That split is sound and stays.

## Alternatives considered

- **Subsume the voice card into the brain.** Rejected: voice (style) is not knowledge (facts). Forcing a learned writing-style model into a human-curated knowledge vault would pollute the vault and lose the automatic, private, edit-derived nature of the voice card. They answer different questions.
- **Delete `MemoryService` as legacy.** Rejected: the voice card is still first-class — it's how transforms/asks sound like Charlie. The ~450 lines earn their keep; deleting them would regress personalization with no replacement (the brain doesn't model writing style).

## Consequences

- The two layers stay separate, each owning one concept. A future change that blurs them (e.g. writing style facts into the vault, or indexing the voice card) should reopen this ADR rather than drift.
- No code change accompanies this ADR — it records a boundary so the two "memory" systems aren't repeatedly re-questioned or accidentally merged.
