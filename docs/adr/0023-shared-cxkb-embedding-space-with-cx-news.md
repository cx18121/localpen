# ADR 0023 — Shared cxkb embedding space with cx-news (one open model, not shared infra)

**Status:** Accepted
**Date:** 2026-06-06
**Related:** [integration design](../superpowers/specs/2026-06-06-cxkb-platform-integration-design.md) (canonical, spans both repos); ROADMAP workstreams W2/W3 + B (hybrid RAG); [ADR 0014](./0014-brain-derived-fts5-index-over-vault.md) (brain = FTS5 over cxkb). Mirrored by `cx-news/docs/adr/0003`.

## Context

Localpen and cx-news are two single-user macOS projects that share one substrate: `~/Documents/cxkb`. Both independently need **embeddings over cxkb** — Localpen for hybrid-RAG brain-grounded writing (workstream B), cx-news for its learned-ranking design (lane centroids + `sim_per_lane` ranking feature). cx-news planned a proprietary cloud embedding API ("self-host later"); Localpen plans local EmbeddingGemma. Left alone, that's two parallel builds in two incompatible vector spaces.

They cannot share a running service — cx-news is cloud Deno/Supabase, Localpen is local Swift/llama.cpp, and Localpen is **local-only by rule** (can't call a cloud embedding API). But they *can* share what makes vectors comparable: the model weights.

## Decision

**Standardize both apps on one open embedding model (EmbeddingGemma) so they share a single vector space — share the model, not the infrastructure.**

- **One canonical open model = one shared space.** cxkb pages, articles, the brain, and cx-news's lanes all become mutually comparable, wherever each app runs the model. cx-news swaps its planned proprietary API for EmbeddingGemma. (Open is mandatory: Localpen's local-only rule forbids a cloud API.)
- **The Mac-local `cxkb-sync` job is the shared producer for cxkb-*page* vectors** — embed once, write to both Localpen's sqlite-vec and cx-news's pgvector. cxkb is slow-changing and not latency-critical, so a Mac-side producer is safe here.
- **Articles stay in cx-news's own cloud path**, embedded with the same model — never routed through the Mac, so cx-news's daily 8am cron is not re-coupled to the Mac being awake.
- **Separate learned heads.** cx-news's logistic reranker and Localpen's voice-LoRA are different models on different objectives; share the embedding *space* and base *models*, never the trained heads.
- **A pinned model-version contract** (model id + version + output dim incl. Matryoshka truncation + pooling + query/document task-prefixes) is the shared interface. A change is a coordinated re-embed of both stores, not a unilateral bump.

## Alternatives considered

- **Full unified Mac pipeline now** (one Mac producer for *everything*, articles included). Rejected: re-couples cx-news's daily cron to the Mac being awake (the failure mode its S02 sync agent fought), and builds shared machinery before either app's own embedding layer exists (likely-wrong abstraction, rework). The shared *space* — the actual payoff — comes from the shared *model*, which this decision already provides; the extra "one physical producer" is the fragile, premature part with little marginal benefit.
- **Separate maps (content + signal only).** Each app keeps its own embeddings; integrate only via the cxkb saves→inbox→brain loop + plain-text signals. Rejected: loses the cross-app vector features (article↔active-project, lanes↔brain) that are the whole point.

## Consequences

- cx-news adopts EmbeddingGemma (per its ADR-0003); Localpen's workstream B uses the same model + contract.
- Cross-app features become possible: Localpen's brain (active projects / `now.md`) as a cx-news ranking feature; cx-news lanes as Localpen writing context.
- Both repos must honor the model-version contract or the shared space silently breaks.
- Coordination is via git + the canonical shared design doc (no live cross-session messaging); the cx-news ADR is authored in Localpen and applied from the cx-news session to avoid clobbering its working tree.
- Phased rollout (P0 adopt contract → P1 content loop → P2 shared cxkb-page producer → P3 cross-app features); P0 is just the decision, so it unlocks without coupling anything yet.
