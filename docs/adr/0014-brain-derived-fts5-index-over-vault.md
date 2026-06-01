# ADR 0014 — The brain is a derived FTS5 index over the Obsidian vault, not an owned store

**Status:** Accepted
**Date:** 2026-06-01
**Related:** extends the product direction of the 2026-06-01 brain pivot; the calendar source ([ADR 0013](./0013-calendar-via-ics-feed.md)) is the first "external context read" this generalizes.

## Context

Localpen is becoming the user's personal AI "brain" — the AI-native layer over his workflow. His knowledge already lives in a well-structured Obsidian vault at `~/Documents/cxkb` (~88 markdown files: `self/`, `projects/`, `topics/`, `sources/`, `journal/`, and the new `areas/`, `people/`, `now.md`). The vault has its own strict operating manual (`cxkb/CLAUDE.md`): `raw/` is immutable, writes go through discuss-first gates, Obsidian + git are the interface.

Localpen needs fast, ranked retrieval over that vault so an Ask can be answered with the user's own context. The current `/cxkb-context` skill uses an "LLM reads `index.md` then drills" approach that the vault's own manual flags as hitting a wall past ~300 lines.

Garry Tan's **GBrain** is the reference design (Compiled Truth + Timeline, self-wiring graph, hybrid retrieval) — but it's built for a 146k-page, multi-client, server-deployed scale (Postgres + pgvector, a Minions job queue, 66 crons, OAuth, team brains, 43 skills). The user needs ~15% of that.

## Decision

**The brain is a derived, rebuildable SQLite FTS5 index over the vault. The markdown is the single source of truth; the index is a disposable cache.** Native Swift only, built on the existing GRDB dependency. No external runtime, no separate process, no Postgres, no job queue.

- **Two databases, never conflated:** the existing `history.sqlite` (durable app state — threads, interactions) and a **new `brain.sqlite`** (derived; delete it and rebuild from markdown — nothing lost).
- **Index layer** (`Localpen/Services/Brain/`): `MarkdownParser` → `KBPage` value types; `BrainIndex` keeps a contentless-external FTS5 table + a wikilink graph in lockstep (explicit sync on upsert/delete, no triggers); `KBWatcher` (FSEvents + 0.75s debounce) drives incremental reindex; `KBSearch` ranks via **bm25 + log-scaled backlink boost** (`-bm + 0.5·log2(1+indegree)`).
- **Engine layer:** `ContextEngine.bundle(for:calendar:)` always includes `self/` + `now.md`, adds top-K query hits, caps to a token budget, returns a `ContextBundle`. **Gated by `BrainAccess.isActive` — off ⇒ the ask prompt is byte-identical to today's.**
- **Index scope:** the wiki layer (`self/`, `projects/`, `topics/`, `sources/`, `journal/`, `areas/`, `people/`, `now.md`). **Excludes `raw/`, `.obsidian`, `.git`** — matching the vault's own "digest set" convention. Raw sources are reachable via the pages that cite them.
- **Embeddings are deferred, not designed out.** `KBSearch.score` is a pure, single seam; local semantic embeddings layer on top of FTS5 later without reworking the contract.

## Alternatives considered

1. **Incorporate GBrain itself.** Rejected: it's a server-scale system (Postgres, Minions queue, crons, OAuth, team brains) — the user needs a single-user local index. Steal its *conventions* (Compiled Truth + Timeline, self-wiring graph) as markdown patterns, not its *code*.
2. **Localpen owns the brain; the vault syncs into it.** Rejected: creates a two-masters sync/dedup problem and splits the brain across two stores. The vault is already the user's brain — Localpen reads it, doesn't replace it.
3. **Embeddings / vector search first.** Rejected for v1: FTS5 + a wikilink-graph boost is enough at ~88 pages and far simpler; embeddings are a clean later addition behind the `score` seam.
4. **Just grep the files per query.** Workable at this scale but gives no ranking; FTS5's bm25 + the backlink boost is the retrieval quality the feature needs, and it scales as the vault grows.

## Consequences

- The index is rebuildable from markdown at any time; schema changes mean "delete + reindex," not a migration.
- Obsidian and git keep working unchanged — the index observes the vault, never owns it.
- A file watcher must run while the app is up; `brain.sqlite` lives beside `history.sqlite` in app support.
- The same query core feeds the future `localpen search` CLI (see [ADR 0016](./0016-hub-surface-and-modes.md) family / the brain plan) — retrieval logic is built to be callable by an external process, not locked in the GUI's memory.
- Verification is unit tests on the pure layers (parser, score, index lockstep) + build; the UI layer keeps the repo's manual-visual-check posture.
