# W3 — Deepened Ask Retrieval (passage-level, graph-expanded, faster)

**Date:** 2026-06-18
**Status:** Design (pre-implementation)
**Relates to:** [ROADMAP.md](../../../ROADMAP.md) W3 ("brain deepened"), [ADR 0022](../../../docs/adr/0022-narrow-to-moat-writing-and-brain-complement-poke.md) (narrow to writing × brain). Builds on W2 brain-grounded writing (`ContextEngine`, chunk infra, mention grounding).

---

## 1. Problem

Brain-grounded ask/draft is only as good as what retrieval surfaces, and the **generic ask path** (a free-form question with no `[[`/`@` mention) under-delivers on three fronts the user feels:

1. **Misses the detail (quality).** Generic retrieval is *whole-page*: `ContextEngine.queryHits` retrieves pages, then `condense()` head-caps each page body at 800 chars. A fact in paragraph 5 of a long note never reaches the model. Chunk-level retrieval exists (`page_chunks`, `ChunkStore`, `Chunker`, `MentionGrounding.rankChunks`) but is wired **only** into mention grounding, not generic ask.
2. **Can't pull connected notes (graph).** The wikilink graph (`links`, `backlinks` tables) is only a faint BM25 tiebreaker. A question whose answer lives in a note *linked from* the obvious hit (a meeting that references a project, a related project) isn't surfaced unless that note independently matches the query terms.
3. **Slower than it needs to be (latency).** The query is embedded **twice** per ask (once in `groundMentions`, once in `queryHits`); the full `page_embeddings` table is reloaded **uncached** on every ask (`EmbeddingStore.loadAll()`); and every ask materializes **all** person+project pages for mention detection even when the query names no one.

W2 demand has surfaced all three (the roadmap pulls W3 forward exactly this far). This spec fixes them in the one place they live: the generic retrieval path.

## 2. What this is / is not

- **Is:** a rewrite of the generic (non-mention) retrieval layer in `ContextEngine` to retrieve **passages (chunks)** instead of head-capped pages, **expand** the candidate set with the 1-hop link-neighbors of the strongest hits (relevance-gated), and **cache/dedupe** the embedding work — plus a strengthened retrieval gold-set gate to prove the quality gain.
- **Is not:** a graph-browsing UI (explicitly deferred — the user chose auto-pull, not navigation). No multi-hop traversal (1-hop only). No cross-encoder rerank, no query expansion, no new embedding model. The always-pages (identity) layer and the mention-grounding layer are unchanged.

## 3. Architecture

`ContextEngine.bundle(for:mentions:)` keeps its three-layer shape; **only the generic layer is rewritten.** Layers fill a shared token budget in order:

1. **Always-pages** (identity: `BrainConfig.alwaysIncludeAreas = ["self"]` + `alwaysIncludeFiles = ["now"]`) — unchanged, claims budget first.
2. **Mention grounding** (`groundMentions`, when people/projects are named) — unchanged.
3. **Generic passage retrieval** — *rewritten* (§4).

The query is embedded **once** at the top of `bundle` and the resulting vector is threaded into both the mention layer and the generic layer (kills the double-embed). The page-vector map is served from a cache invalidated on index change (kills the per-ask full table scan).

### Degradation (preserved)
When embeddings are absent / the embedding server is down / brain is off, there is **no query vector**, so the generic layer falls back to **today's page-level BM25 path unchanged** (chunk ranking and graph expansion both require the query vector). Brain-off stays byte-identical. Graph expansion and passage retrieval are improvements layered on the hybrid path, never a hard dependency.

## 4. The generic passage-retrieval pipeline

Replaces `queryHits(for:)`. Inputs: the query string, the shared query vector `qv`, and the set of paths already covered by the always/mention layers (to avoid double-inclusion). Steps:

1. **Candidate pages.** Run the existing hybrid search `KBSearch.hybridSearch(query, queryVector: qv, vectors: cachedVectors, limit: kCandidatePages)` with `kCandidatePages = 10` (a wider net than today's `topK = 6`, since chunk ranking will trim it). BM25⊕dense RRF, unchanged internally.
2. **Graph expansion (relevance-gated, 1-hop).** Take the **top 2** candidate pages as seeds. For each seed, collect its 1-hop neighbors in both directions: inbound via `BrainIndex.backlinks(toTitle:)` (exists) and outbound via the new `BrainIndex.outboundLinks(fromPath:)` (§5). Add neighbor pages to the candidate set. Neighbors are *candidates only* — they earn budget solely by chunk relevance in step 4, so a linked-but-irrelevant note contributes nothing.
3. **Assemble candidate paths.** `candidatePaths = (hybrid pages ∪ neighbor pages) − alreadyCoveredPaths`, deduped, preserving the hybrid rank order for stability.
4. **Passage ranking.** `ChunkStore.loadChunks(forPaths: candidatePaths)` (path-scoped, not a full-vault scan), then rank every chunk by cosine to `qv` via `MentionGrounding.rankChunks(_, queryVector: qv, limit:)`.
5. **Budget fill (per-page capped).** Walk ranked chunks best-first; include a chunk if its page hasn't already hit `perPageChunkCap = 2` **and** the running token total (chunk text length / 4) stays under the remaining budget. Stop when budget is exhausted or chunks run out. The per-page cap guarantees passage diversity (one long note can't monopolize the slice).
6. **Emit.** Each included chunk becomes a `kb [Title]: <chunk text>` line (chunks are already ~512 chars from `Chunker`; a light cap guards the rare oversized chunk). Provenance for each is recorded (`ContextBundle.Provenance`, kind `.search` / a new `.linked` for graph-pulled neighbors) so result Source chips stay honest.

### Budget
`BrainConfig.maxContextTokens` stays ~1200 (tunable). The generic slice now holds **many small relevant passages** instead of a few head-capped pages. New config knobs: `kCandidatePages` (10), `graphSeedCount` (2), `perPageChunkCap` (2). `topK`/`perPageCharCap` remain for the BM25 fallback path.

## 5. New / changed components

- **`ContextEngine`** — rewrite the generic layer (`queryHits` → the §4 passage pipeline); embed the query once in `bundle` and thread `qv` everywhere; pull the page-vector map from the cache (§ below). Mention/always layers untouched except to receive `qv` instead of re-embedding.
- **`BrainIndex.outboundLinks(fromPath:) -> [KBPage]`** — new. Reads the existing `links` table (`src_path = ?`, resolved `dst_path IS NOT NULL`), returns the linked-to pages. (Today only inbound `backlinks(toTitle:)` is exposed; the `links` table already stores outbound edges.)
- **Cached vector map** — the page-vector map (`EmbeddingStore.loadAll()`) is loaded once and reused across asks, invalidated when the index changes (reindex/upsert/delete). Mechanism: `BrainIndex` exposes a monotonically-increasing `indexVersion` (bumped wherever the graph/FTS are recomputed); `ContextEngine` holds `(version, [String:[Float]])` and reloads only on a version mismatch. This is the single biggest latency win and also removes a source of per-ask GC churn.
- **Cached mention candidates** — `detectMentions` stops materializing all person+project `KBPage`s per ask; it reuses the candidate-title set already loaded for autocomplete (`candidateTitles()`), refreshed on the same `indexVersion` signal.

## 6. Verification

The current `HybridGoldSet` gate only asserts `hybridHits >= bm25Hits` (no regression) on project/topic/self queries, with no absolute floor. Strengthen it — this is how we prove the three pains are fixed:

- **Absolute Recall@5 floor** (e.g. ≥ 0.8) on the gold set, not just "≥ BM25".
- **Broader query types** in `Fixtures/retrieval_goldset.json`: add people, meeting, and journal queries (the types most dependent on chunk/graph retrieval, absent today).
- **Passage-level assertion:** for a deep-in-page fact, assert the *expected chunk* is retrieved (passage hit), not merely that the page ranks. Directly guards pain #1.
- **Graph case:** a query whose answer lives in a note linked-from (not directly matching) the obvious hit must surface that note's passage. Directly guards pain #2.
- **Embed-once assertion:** a unit test (fake/counting embedding service) proves a single ask embeds the query exactly once. Directly guards pain #3.
- **Brain-off byte-identical invariant** holds (existing test extended to the new path).

Pure ranking/assembly logic is unit-tested with fixtures from the real vault (Rule 5); the model/server paths are gold-set-gated (run with the embedding server up).

## 7. Degradation & failure isolation

- No embeddings / server down / brain off → generic layer = today's BM25 page-level path; no graph expansion; byte-identical when off.
- A page with no chunk vectors (unembedded) simply doesn't rank — never errors.
- `outboundLinks` over a page with unresolved wikilinks skips the unresolved edges (no crash).
- Graph expansion that finds no neighbors → the pipeline is exactly the hybrid-chunk path without expansion.

## 8. Build order

1. `BrainIndex.outboundLinks(fromPath:)` + `indexVersion` stamp — pure-ish, unit-tested against a temp index.
2. Cached vector map + single query embed in `bundle` (thread `qv`) — the latency fixes; assert embed-once.
3. Cached mention candidates (reuse `candidateTitles`) — latency.
4. The §4 passage pipeline (candidate pages → graph expansion → chunk rank → per-page-capped budget fill) replacing `queryHits` — the core.
5. Strengthen `HybridGoldSet`: absolute floor + new query types + passage + graph assertions; extend the brain-off invariant test.
6. Gold-set verification with the embedding server up; live user check on the real vault.

## 9. Done-when

- A free-form ask surfaces the *relevant passage* from a long note (not the head-cap), and pulls a *linked* note's passage when that's where the answer lives — both visible in the result's Source chips.
- The query is embedded once per ask; the vector map is cached across asks; mention detection no longer loads the whole person/project set per ask.
- The strengthened gold set passes its absolute Recall floor across the broader query types, including the passage and graph cases; brain-off stays byte-identical.
- No graph UI, no multi-hop — those remain explicitly future.
