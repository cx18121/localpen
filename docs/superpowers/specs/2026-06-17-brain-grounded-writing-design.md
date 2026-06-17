# Brain-Grounded Writing — Design Spec

**Date:** 2026-06-17
**Workstream:** W2 — the wedge (per [ROADMAP.md](../../../ROADMAP.md))
**Rung:** 1 — read + draft, never act ([ADR 0022](../../../docs/adr/0022-narrow-to-moat-writing-and-brain-complement-poke.md))

---

## 1. Purpose

The wedge that only Localpen can do: writing in your editor, grounded in your private brain.
The flagship gesture —

> *"rewrite this reply using what I know about [[Ana]], in my voice."*

— produces a draft that genuinely reflects your notes about Ana **and** sounds like you. Poke can
reach neither your editor nor your local vault; this is uniquely Localpen's.

Two existing pieces already half-deliver this and are **reused, not rebuilt**:

- **Voice** — `MemoryService.compose()` already injects the voice card + facts into respond / custom
  / ask prompts ([workstream A](2026-05-27-memory-design.md)).
- **Brain at query-time** — the ask path already calls `ContextEngine.bundle(for:)` and pulls hybrid
  (BM25 ⊕ dense RRF) context ([ADR 0014](../../../docs/adr/0014-brain-derived-fts5-index-over-vault.md)).

W2 closes two real gaps: (a) the **transform/respond/custom path pulls no brain context** (only
voice), and (b) retrieval is **not mention-aware** — it hashes the whole query into hybrid search
instead of prioritizing the specific people/projects you name. W2 adds a mention-aware retrieval
seam shared by all three user-steered actions, and — because "what I know about Ana" deserves
paragraph-level precision — a **chunk-level embedding layer** under it.

## 2. What W2 is not

Naming the boundaries so they don't accrete:

- **No grounding for the 6 fixed quick-actions.** Proofread / Polish / More formal / More casual /
  Shorter rewrite the selection mechanically and take no target entity. Brain grounding applies
  only to the three **user-steered** actions where you can name an entity: `respond`, `custom`,
  `ask`. (Mirrors the existing `MemoryService` voice-gating, which already excludes proofread /
  shorter.)
- **No general-ask retrieval rewrite.** Chunk-level retrieval here serves **mention grounding only**
  (scoped to 1–3 named pages). The broad page-level `KBSearch.hybridSearch` ask path and its
  gold-set recall gate are **untouched**. Generalizing chunk retrieval to the whole ask path is the
  natural W3 ("faster ask my notes") item.
- **No acting.** Rung 1 holds — Localpen drafts; the human does the final paste. ([ADR 0022](../../../docs/adr/0022-narrow-to-moat-writing-and-brain-complement-poke.md))
- **No new model, no new hotkey.** Same Qwen 2.5 7B + EmbeddingGemma, same ⌃⌥Space.
- **No always-on context.** Brain stays the one auto source ([ADR 0020](../../../docs/adr/0020-opt-in-context-sources.md)); mentions are
  detected from what you write/select, surfaced as removable chips — never silently injected
  invisibly.

## 3. Trigger model

How a person/project becomes "mentioned":

- **Explicit** (`[[name]]` or `@name` in the instruction / custom / ask field) — **authoritative**.
  Resolves to that exact page and grounds without confirmation: you named it on purpose. A live
  autocomplete over brain titles fires on `[[` / `@` (the cxkb-native gesture; also how users
  *discover* the feature).
- **Auto-detected** — names in the instruction/selection that match a person/project page title
  (normalized, word-boundary) are added too, but as **removable chips** in a pre-generation chip
  row, and always shown in result provenance. The W1 accept-reject diff is the backstop.
- **Markup is an input gesture, not model input.** The resolver strips `[[ ]]` / `@` tokens from the
  instruction the model sees ("…what I know about Ana"); the grounding block carries the notes. The
  model never parses or echoes wikilink syntax.

## 4. Architecture

### 4.1 Brain-infra layer (the W2 foundation)

Chunk-level embeddings so grounding is paragraph-precise, not first-800-chars.

- **`Chunker`** (pure, no I/O) — `page body → [chunk]`. Split on headings / paragraph breaks; target
  ~512 chars, merge runts, hard-cap ~1000. Unit-testable against real vault pages.
- **`page_chunks` table** (brain.sqlite migration) —
  `(path, chunk_index, text, vector, dim, model, mtime)`, PK `(path, chunk_index)`. Stores the chunk
  **text** so grounding emits a snippet without re-reading the file. Mirrors `page_embeddings`'s
  `mtime`-staleness pattern. Added alongside `page_embeddings`, which is left intact (it still
  serves the page-level ask path). Vault scale (~81 pages → a few hundred chunks) makes the
  redundancy negligible.
- **`ChunkStore`** — `upsert(path, chunks:)`, `loadChunks(forPaths:)` (scoped, **not** whole-vault),
  staleness via the same `e.mtime <> p.mtime` join `EmbeddingStore` uses.
- **Backfill** — extend `BrainIndex.backfillEmbeddings` + the staleness query: a changed page
  re-chunks and re-embeds its chunks (delete-then-insert by path). Chunks embed through the existing
  `EmbeddingService` (`.document` kind, `title: {pageTitle} | text: {chunk}`) — **no embedding-service
  changes**. Backfill stays background; never blocks a write.

### 4.2 Mention-aware retrieval

- **`MentionResolver`** (pure, testable) — input: instruction + selection + the brain page list
  (people + projects). Output: `[ResolvedMention]` (page · neighborhood · `explicit|auto` origin)
  and `[unresolved candidate]`.
  - *Explicit:* parse `[[name]]` / `@name` → `BrainIndex.pageByTitle` + `ProjectMatcher.normalize`
    fuzzy match. Ambiguity → shortest-title wins (existing `ProjectMatcher` tiebreak).
  - *Auto:* scan remaining text for tokens matching person/project titles (normalized, **word-
    boundary** — "Ana" must not match inside "Banana"), marked `auto`.
  - *Neighborhood:* `BrainIndex.backlinks(toTitle:)` per resolved page, bounded.
- **`MentionGrounding`** (pure) — turns a `ResolvedMention` into context lines:
  1. one-line **structured header** — people: `{tier} · last contact {n}d · follow-up: {x}` via
     `PeopleInsights.person`; projects: status/stage frontmatter. Only present fields; missing →
     omitted.
  2. **chunk-ranked body** — embed the reply/instruction as a query, `loadChunks(forPaths: P)` over
     the entity + neighborhood pages, cosine-rank, fill the mention budget with top chunks. Each
     emitted with provenance (path · chunk_index): own-page chunks as `kb [Ana › heading]: {chunk}`,
     neighborhood chunks as `kb [Ana ✕ Project Atlas]: {chunk}` (so the model reads the subject vs.
     related context).
  - *Degradation:* if chunks are unavailable (server down / page unembedded), fall back to
    `ContextEngine.condense` head-snippet of the page. Still grounded, just less precise — an
    explicit mention is **never** silently dropped.
- **`ContextEngine.bundle(for:mentions:)`** — budget order:
  `self/ + now.md` → **resolved mention pages (explicit before auto)** → mention neighborhood →
  generic query hits. Named entities claim budget first; if budget runs out, generic hits drop,
  never the person you named. Provenance gains a `.mention` reason.
- **Budget policy** (concrete) — within the existing `maxContextTokens` (~1200), after self/now
  claim theirs, the remainder is the *mention budget*. Each resolved mention gets a guaranteed
  **primary slice** (its header + at least its top-ranked chunk) before any mention's neighborhood
  is funded; multi-mention splits the primary allocation **evenly** across named entities (so
  `[[Ana]] and [[Ben]]` each land before either's backlinks). Neighborhood + generic query hits then
  fill whatever budget remains, in that priority. A mention whose header alone overflows the
  remaining budget still emits the header (the cheapest grounding) and drops its chunks.

### 4.3 Wiring & UI

- **`runStream()`** (respond / custom path) — today only calls `memory?.compose()`. Add the
  `bundle(for:mentions:)` call so transforms get grounding. **`startAskStream()`** — its existing
  `bundle` call gains the `mentions:` argument. `ActionPrompts.askUserMessage` is unchanged:
  grounding lines are `ContextKind.knowledge`, already sorted to rank 4 in the `<context>` block.
- **Mention autocomplete** — `[[` / `@` in the custom / respond / ask field opens a popover over
  brain titles (people + projects), live-filtered.
- **Pre-generation chip row** — across all three surfaces: explicit mentions pre-added; auto-detected
  removable in one click; unresolved shown greyed ("no notes found").
- **Provenance display** — the result shows which pages grounded the draft, openable.

## 5. Prompt shape

Three regions kept distinct so the model never blurs *your voice* / *facts about Ana* / *the text to
rewrite*:

**System** (`MemoryService.compose`, unchanged ordering):
```
{base action prompt}
User writing voice: {voiceCard}
Facts about the user: - …
```

**User message** (`ActionPrompts`, the `<context>` block):
```
<context>
kb [Ana]: close tier · last contact 21d ago · follow-up: reply re: launch
kb [Ana › Launch plan]: {chunk most relevant to the reply…}
kb [Ana ✕ Project Atlas]: {neighborhood chunk…}
</context>

rewrite this reply using what I know about Ana, in my voice:
{selected reply text}
```

## 6. Degradation & error handling

Every failure path degrades to **exactly** pre-W2 behavior; a write is never errored by the brain.

| Condition | Behavior |
|---|---|
| Brain disabled (`isBrainEnabled()==false`) | `bundle` → `.empty`; resolver never runs; prompt **byte-identical** to no-brain. (Existing invariant, preserved.) |
| Embedding server down / page unembedded | Chunk rank unavailable → fall back to head-`condense` of the resolved page. Mention still grounded. |
| Mention resolves to nothing (`[[Z6]]`) | Unresolved chip (greyed, "no notes found"); markup stripped; generate ungrounded. No silent drop. |
| Ambiguous match (two `[[Sam]]`) | Shortest-title wins; resolved page shown in the chip so it's correctable. |
| Stale chunks mid-write | Use whatever's embedded now; never block generation on a re-embed. Backfill is background. |

## 7. Testing

Every fixture traces to real cxkb pages — never invented ([Rule 5](../../../CLAUDE.md)).

- **`Chunker`** (pure): heading splits, runt-merge, hard-cap, empty / one-line pages. Golden cases
  from real vault pages.
- **`MentionResolver`** (pure): explicit `[[ ]]` / `@`; auto-detect at word boundaries (not
  substrings); multi-mention; unresolved; ambiguous tiebreak.
- **`MentionGrounding`** (pure): budget split (primary slice guaranteed before neighborhood);
  multi-mention fairness; chunk-rank order; degradation-to-condense when no chunks.
- **`ContextEngine.bundle(for:mentions:)`**: mention pages claim budget after self/now, before query
  hits; provenance reasons correct.
- **Integration (load-bearing):** brain-disabled prompt **byte-identical** to pre-W2 — guards the
  degradation invariant. Mirrors the existing brain on/off prompt-equality test.
- **Recall gate:** the page-level **ask** gold-set recall is **unchanged** — proves chunking didn't
  disturb the ask path.

## 8. Build order

Infra-first, so the writing feature builds on validated retrieval:

1. **Chunk infra** — `Chunker` → `ChunkStore` + `page_chunks` migration → backfill wiring. (Verify:
   chunks embed, staleness invalidates, recall gate green.)
2. **Mention retrieval** — `MentionResolver` + `MentionGrounding` + `bundle(for:mentions:)`.
3. **Wiring** — `runStream` (respond/custom) + `startAskStream` (`mentions:` arg).
4. **Input UX** — `[[` / `@` autocomplete + pre-generation chip row.
5. **Provenance display** in results.

Each step compiles + tests green before the next. Final verification is a hand visual check by the
user (per working style) — the flagship gesture end-to-end.
