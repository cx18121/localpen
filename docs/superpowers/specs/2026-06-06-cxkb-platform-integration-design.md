# cxkb Platform Integration — Localpen ↔ cx-news (design)

**Date:** 2026-06-06
**Status:** Accepted (2026-06-06) — option 1 (shared model = shared space, phased) chosen over option 2 (full unified Mac pipeline) and option 3 (separate maps).
**Spans two repos:** `localpen` (local Swift writing tool) and `cx-news` (cloud Deno/Supabase news recommender). Canonical copy lives here in `localpen`; a cross-referencing ADR is added to each repo (`localpen/docs/adr/0023`, `cx-news/docs/adr/0003`).
**Related:** localpen ROADMAP W2/W3 + workstream B (hybrid RAG), ADR 0014 (brain = FTS5 over cxkb); cx-news learned-ranking design (2026-06-06) + ADR-0002 (layered learned reranker).

## Context

Two single-user macOS projects share one data substrate: `~/Documents/cxkb`. They are converging on the *same* underlying capability from opposite ends:

- **Localpen** (workstream B): local **EmbeddingGemma** over cxkb (sqlite-vec) → hybrid RAG for brain-grounded writing. Fully local, no cloud.
- **cx-news** (learned-ranking design): embed articles, cluster the user's positively-labeled embeddings into **lanes** (a multi-vector taste fingerprint), use per-lane cosine as a ranking feature + retrieval steering. Planned via a **cloud embedding API** (Voyage/OpenAI), "self-hostable later for $0."

Both independently need *embeddings over cxkb*. The opportunity is to make that one shared substrate instead of two parallel builds.

## Thesis: share the model, not the infrastructure

The two apps cannot (and should not) share a running service — cx-news is cloud Deno/Supabase, Localpen is local Swift/llama.cpp, and Localpen is local-only by hard rule. But they **can** share the thing that makes vectors comparable: **the embedding model weights.**

If both standardize on **one open embedding model (EmbeddingGemma)**, then cxkb pages, articles, Localpen's brain, and cx-news's lanes all live in **one comparable vector space** — regardless of where each app runs the model. cx-news's "self-host later" simply becomes "adopt the shared open model." That single decision turns two apps into a **personal ML platform over the vault.**

## Decision (option 1, refined)

1. **One canonical open embedding model = one shared vector space.** EmbeddingGemma (open; runs locally in llama.cpp/MLX *and* in cx-news's cloud path). cx-news swaps its planned proprietary embedding API for this model. Required because Localpen is local-only and cannot call a cloud embedding API.
2. **The Mac-local `cxkb-sync` job is the shared producer for cxkb-*page* vectors.** It already pushes cxkb digests to Supabase; extend it to embed cxkb pages *once* (local EmbeddingGemma) and write vectors to **both** Localpen's sqlite-vec store and cx-news's pgvector. cxkb changes slowly and is not latency-critical, so a Mac-side producer is safe here.
3. **Articles stay in cx-news's own cloud path**, embedded with the *same model* — **not** routed through the Mac. This keeps the shared vector space without re-coupling cx-news's daily 8am cron to the Mac being awake (the failure mode its S02 sync agent fought hard to avoid).
4. **Separate learned heads.** cx-news's logistic reranker (engagement objective) and Localpen's voice-LoRA (writing objective) are different models on different signals. Share the embedding *space* and base *models*; never the trained heads.

### The model-version contract (load-bearing)

For the spaces to stay comparable, both apps MUST pin an identical embedding contract: **model id + version + output dimension (incl. any Matryoshka truncation) + pooling mode + the query/document task-prefixes.** If one app upgrades the model, the other's stored vectors become incomparable until re-embedded. This contract is the shared interface; it lives in this doc and is referenced by both ADRs. Changing it is a coordinated migration, not a unilateral bump.

## Shared seams

1. **Shared vector space over cxkb** — same model → article↔cxkb-page and lane↔brain cosines are all valid. cx-news's `sim_per_lane` and Localpen's retrieval become the same math on the same space.
2. **Shared cxkb-page embedding producer** — the `cxkb-sync` Mac job; one model, computed once, two stores.
3. **Cross-app taste signals** — Localpen's brain (active projects / `now.md`) → a cx-news ranking feature ("boost articles near what I'm working on"). cx-news's lanes (what you've been reading) → writing context in Localpen. Bidirectional, in one space.
4. **cxkb content loop (already half-wired)** — cx-news saves → `cxkb/raw/inbox` → Localpen's dream cycle → brain → brain-grounded writing knows what you've read. Make it deliberate.
5. **Optional shared reranker model** — cx-news defers a neural cross-encoder; Localpen's B uses bge-reranker-v2-m3. Same open model, reusable as cx-news's deferred reranker feature behind its eval gate.

## Honest boundaries (where NOT to integrate)

- **No merged runtime** — cx-news stays cloud; Localpen stays local. Shared substrate, not shared infra.
- **No Mac in the daily article loop** — see decision #3.
- **No shared learned weights** — see decision #4.
- **Localpen local-only is inviolable** — hence the model must be open, not a cloud API.

## Phasing

- **P0 — Adopt the contract.** Both repos record the shared model + version contract (this doc + the two ADRs). cx-news's learned-ranking Phase 0/1 builds against EmbeddingGemma instead of a proprietary API; Localpen's B builds against the same. No new coupling yet — just a shared choice so the spaces match when each app builds its own layer.
- **P1 — cxkb content loop.** Tighten the saves→inbox→brain path (mostly exists). Cheapest, immediate, no vector dependency.
- **P2 — Shared cxkb-page producer.** Extend `cxkb-sync` to emit cxkb-page vectors to both sqlite-vec and pgvector.
- **P3 — Cross-app vector features.** brain/projects → cx-news ranking feature; lanes → Localpen writing context.

Each phase is independently shippable; P0 is just a decision, so it gates nothing but unlocks everything.

## Open decisions / risks

- **EmbeddingGemma task-prefix discipline** (query vs document prefixes) materially affects quality and MUST match across apps — part of the contract.
- **Dimension/MRL truncation** must match across stores (e.g. both store 256-dim) or cosines are meaningless.
- **pgvector (cloud) vs sqlite-vec (local)** are different stores of the *same* vectors — fine; the space is shared via the model, not the store.
- **Cross-session coordination** — both repos are edited by separate Claude Code sessions. This canonical doc + git is the coordination channel (no live messaging); the cx-news ADR is authored here and applied from the cx-news session to avoid clobbering its working tree.

## Resume framing

*"Designed a personal ML platform around a knowledge vault — a single open-model embedding space shared by a local writing assistant (fine-tuned voice + hybrid RAG) and a cloud news recommender (layered LLM + learned reranker + per-lane Thompson-sampling exploration), with a Mac-local pipeline producing the canonical cxkb vectors for both, under a strict honesty/legibility constraint."*
