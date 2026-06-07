# Parallel Build Map — Localpen ML push + integration (Superset branches)

**Date:** 2026-06-06
**Purpose:** carve the "do everything" program into **independent branches** that can run in parallel as Superset worktree-agents, with dependencies and merge order made explicit so parallel agents don't collide. One branch = one Superset agent = one worktree.

**Source designs:** ROADMAP W1; research briefs for A (voice LoRA) / B (hybrid RAG) / D (inference opt); integration spec + ADR 0023 (shared EmbeddingGemma vector space). cx-news work happens in its own repo/session.

---

## The branches

| Branch | Scope | Subsystems it touches | Independent? |
|---|---|---|---|
| **`feat/w1-diff-view`** | W1: inline word-level diff + accept/reject for transform actions. Design already complete. | `Panel/ResultView`, `ResultToolbar`, `PanelController` (showDiff), new `Services/TextDiff.swift`, `Panel/DiffText.swift` | ✅ Fully independent (UI only, no ML) |
| **`feat/voice-data-exporter`** | A, part 1: SQLite→JSONL dataset exporter (instruction/original/accepted-edit pairs) + cxkb-prose chunker → blended training JSONL. Read-only on the existing store. | new exporter in `LocalpenCLI` (or a script), reads `Persistence` + cxkb | ✅ Independent (read-only; new files) |
| **`feat/inference-harness`** | D, part 1: measurement harness — `llama-bench` wrapper, server `timings` logging, spec-acceptance logging. The eval/rigor substrate. | new `scripts/bench`, `LlamaServerController` (timings logging) | ⚠️ Mostly independent; **shares `LlamaServerController`** |
| **`feat/hybrid-rag`** | **B (the linchpin):** EmbeddingGemma via a 2nd `llama-server`, sqlite-vec store, RRF fusion in `KBSearch`, optional bge-reranker. Owns the embedding-model contract both repos depend on (ADR 0023). | `Brain/KBSearch`, `Brain/BrainIndex`, new `EmbeddingService`, `LlamaServerController` (spawn embed/rerank) | ⚠️ Linchpin; **shares `LlamaServerController`** + Brain |
| **`feat/inference-quickwins`** | D, part 2: `--cache-type-k/v q8_0`, n-gram/prompt-lookup spec for rewrites, 0.5B draft for ask-notes. | `LlamaServerController` (flags) | ❌ Depends on harness (to measure) + collides on `LlamaServerController` |

cx-news side (separate session/repo, you drive): **adopt EmbeddingGemma in learned-ranking Phase 0/1** + apply ADR 0003. Coordinates with `feat/hybrid-rag` only via the **model-version contract** (already pinned in the integration spec) — no code coupling.

---

## The one collision hotspot: `LlamaServerController`

Three branches want to touch it (harness=timings, hybrid-rag=embed/rerank spawn, quickwins=flags). Three branches on one file = merge pain. **Mitigation:**
- Land a tiny **`feat/llama-server-seams`** prep branch FIRST that adds the extension points (timings hook + a way to spawn auxiliary server instances + a flags struct), merge it, then branch the other three off `main` so each only *fills in* its seam. **Or** simplest: let `feat/hybrid-rag` own all `LlamaServerController` changes and have harness/quickwins rebase on it.

Recommendation: the prep-branch route — it's ~30 min and removes the conflict entirely.

---

## Recommended parallel waves (merge order)

**Wave 0 (serial, ~30 min):** `feat/llama-server-seams` → merge. Removes the hotspot.

**Wave 1 (fully parallel — 4 agents):**
- `feat/w1-diff-view` (independent)
- `feat/voice-data-exporter` (independent)
- `feat/inference-harness` (off the seams branch)
- `feat/hybrid-rag` (off the seams branch) ← the big one / linchpin

**Wave 2 (after its deps):**
- `feat/inference-quickwins` (after harness merges, so wins are measured; rebases on hybrid-rag's server changes)
- cross-app vector features (P3: brain→cx-news signal, lanes→writing) — **after** hybrid-rag lands, since they need the shared vector space live.

Merge anytime: w1-diff-view, voice-data-exporter (touch nothing else).

---

## Per-branch acceptance criteria (the agent's "done")

- **w1-diff-view:** `TextDiff` unit tests pass (substitution/insert/delete/no-change/multiline); diff renders for transform actions only; ⌥D toggles; ⌘↩ still pastes clean text; `xcodebuild test` green.
- **voice-data-exporter:** produces a blended JSONL (instruction pairs + prose chunks) from the live DB + cxkb; held-out split; row-count + schema asserted in a test; no training yet.
- **inference-harness:** emits tok/s, TTFT, and (when spec on) acceptance for the two real workloads (rewrite vs ask-notes); documented run command.
- **hybrid-rag:** EmbeddingGemma served + cxkb embedded into sqlite-vec; `KBSearch` returns RRF-fused BM25+dense; a small gold-set shows Recall@5 ≥ FTS5 baseline; honors the ADR-0023 model-version contract; tests green.
- **inference-quickwins:** each change shows a measured win (or is dropped) via the harness; KV stays q8_0 symmetric (FA requirement); no quality regression on a blind rewrite check.

---

## Honest notes
- Solo dev + `xcodebuild` verify loop: each branch still needs you to build/verify/merge. 4–5 parallel branches is the realistic ceiling before review becomes the bottleneck — the constraint is your review throughput, not agent count.
- `feat/hybrid-rag` is the linchpin: it's the shared embedding layer both Localpen *and* cx-news lean on. If you only push two branches hard, make them hybrid-rag + the seams it needs.
- ROADMAP.md still lists W1/W2/W3; folding A/B/D + this map into it is a small follow-up (not blocking).
