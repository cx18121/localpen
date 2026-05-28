# Memory (sub-project A) — Design Spec

**Date:** 2026-05-27
**Roadmap:** [ROADMAP.md](../../../ROADMAP.md) sub-project **A**. First step toward the local-assistant north star; also directly improves the writing tool already shipped.
**Status:** Design — awaiting user review before planning.

---

## Goal

Localpen learns the user's writing **voice** and a small set of **facts** about them, implicitly from
persisted interactions, and conditions generation on them — so rewrites and replies sound like the user
wrote them, without the user ever managing a memory UI. A lightweight inspect/edit view exists as a safety
valve, not a chore.

This is a **single-user, local** feature: the model is already running (llama.cpp), and every interaction
is already persisted to SQLite ([ADR 0006](../../../docs/adr/0006-persist-interactions-from-day-1.md)). No
network, no embeddings pipeline, no new SPM dependency.

## Research basis

The mechanism choices below are evidence-backed (full sources in the research synthesis that preceded this
spec). The findings that *shaped the design*:

- **LLM-summarized profiles beat raw context** for stable conditioning (Guided Profile Generation reports
  ~37% gain over feeding raw history). → the **voice card**.
- **Few-shot raw exemplars anchor voice harder than an abstract description**, especially for informal text;
  **~5 is the sweet spot**, more barely helps. → **card + 3-5 exemplars**.
- **Topical-similarity retrieval of exemplars HURTS style fidelity** ("Catch Me If You Can?", 2025) — pulling
  past samples that match the current topic *reduces* voice quality. Select for **stylistic diversity /
  recency, never topic match**. → no embeddings; `ORDER BY RANDOM()`/recency.
- **A wrong profile poisons every rewrite** (a 7B model faithfully applies a hallucinated trait). →
  **cold-start gate** (no card below a sample threshold) + **inspect/edit** + **voice/facts kept separate**
  so a voice misfire can't corrupt a fact.
- **Voice and facts are different problems** — fuzzy/evolving vs. discrete/high-precision. → two fields, two
  injection rules.

## Scope

**In:**
- A `style_profile` store (single evolving row) holding a voice card + facts list + bookkeeping.
- Background, threshold-triggered **profile generation** via a local-model call over recent interactions.
- **Action-aware injection** of card (+ facts where relevant) + per-request raw exemplars into generation.
- A minimal **inspect/edit** surface for the card + facts, plus "forget everything."

**Out (deferred):**
- Stylometric drift guardrail (Tier 2 — offline comparison of output vs. baseline). Named, not built.
- Embedding/similarity retrieval (evidence says it backfires for style).
- Activation steering / LoRA / fine-tuning (Tier 3, research-grade, needs hidden-state access llama.cpp
  doesn't expose).
- Cross-device sync (never — local-first).
- Per-app voice variants (the data supports it eventually; v1 is one global voice).

## Components

### 1. `StyleProfile` (model)
A struct mirroring a single `style_profile` row:
- `voiceCard: String?` — ~150-250 word natural-language description; `nil` until cold-start threshold passed.
- `facts: [String]` — short, conservative bullets; may be empty.
- `generatedAt: Int64?` — unix epoch of last generation; `nil` if never generated.
- `sampleCount: Int` — number of interactions the current profile was built from (drives regeneration
  threshold and the cold-start gate).
- `userEdited: Bool` — set when the user hand-edits the card/facts; see "Regeneration vs. user edits."

Stored as a single row (id = 1, upserted). GRDB `Codable` record like `Interaction`.

### 2. `style_profile` table (migration v3)
New migration appended to `Persistence.migrate` (no changes to `interactions`/`threads`):

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | always 1 (single-row) |
| `voice_card` | TEXT | nullable |
| `facts` | TEXT | JSON-encoded `[String]` |
| `generated_at` | INTEGER | nullable unix epoch |
| `sample_count` | INTEGER | not null, default 0 |
| `user_edited` | INTEGER | 0/1, not null, default 0 |

### 3. `MemoryService` (new, `@MainActor`)
The seam. Owns profile lifecycle and prompt composition. Depends on `Persistence` (read interactions, R/W
profile) and `StreamingClient` (background generation).

Responsibilities:
- **`profile() -> StyleProfile`** — load the current profile (cached in memory; refreshed after generation).
- **`maybeRegenerate()`** — called after each saved interaction; decides (cheaply, see thresholds) whether to
  kick a background generation. Single-flight: never two generations at once.
- **`generateProfile()`** — the background pass: pull a sample of recent interactions, build the
  summarization prompt, stream a completion from the local model, parse it into `voiceCard` + `facts`,
  persist. Does **not** block any user-facing generation. Skips silently on model error (keeps last profile).
- **`memoryPreamble(for action: Action) -> MemoryInjection`** — returns the action-gated text to compose into
  a generation (see Injection). Pure/sync: reads cached profile + does one cheap SQL pull for exemplars.

### 4. Injection composition (integration into `PanelController`)
Two existing generation entry points compose the preamble; **`registry.systemPrompt(for:)` is the base** and
memory wraps it (the static `ActionPrompts.styleContext` global is *not* sufficient — the registry path can
bypass it, so injection happens at the call site):

- One-shot — `PanelController.swift:589`: `let systemPrompt = registry.systemPrompt(for: action)` becomes
  `let systemPrompt = memory.compose(base: registry.systemPrompt(for: action), for: action)`.
- Conversation — `PanelController.swift:740`: the `("system", ActionPrompts.conversationSystem)` message
  becomes `("system", memory.compose(base: ActionPrompts.conversationSystem, for: .custom))` (conversation is
  free-form → treated like custom for gating: card + facts + exemplars all eligible).

`compose(base:for:)` assembles, in order: `base` system prompt → (if eligible) voice card → (if eligible)
facts → (if eligible) exemplars block. Exemplars are injected in the **system** prompt as labeled samples
("Here are samples of how the user writes:\n---\n…"), not as fake user turns.

### 5. Inspect/edit surface (reached from recents)
**Placement (decided): a pinned "Your writing profile" row at the top of the existing recents/thread list**,
which opens the profile inline (no new top-level surface; minimal state-machine wiring). Visual prototype:
`sketches/memory-surface-prototype.html` (variant A). The opened view shows:
- The voice card — multi-line, freely **editable** text.
- The facts list — **editable** bullets, add/remove.
- "Regenerate now" and "Forget everything" (clears `style_profile`; does **not** touch `interactions` unless
  the user also clears history — distinct actions).
- **Cold-start state** (before the 15-interaction gate): an honest "still getting to know how you write —
  N/15" message with progress, *not* a fabricated card. This is load-bearing per the research (a guessed
  card degrades every rewrite).

Editing the card or facts sets `user_edited = 1`.

## Injection rules (action-aware)

| Action | Voice card | Facts | Exemplars |
|---|---|---|---|
| `proofread` | ✗ (must not drift) | ✗ | ✗ |
| `shorter` | ✗ | ✗ | ✗ |
| `polish` | ✓ | ✗ | ✓ |
| `moreFormal` | ✓ | ✗ | ✓ |
| `moreCasual` | ✓ | ✗ | ✓ |
| `respond` | ✓ | ✓ | ✓ |
| `custom` | ✓ | ✓ | ✓ |
| conversation | ✓ | ✓ | ✓ |

Rationale: `proofread`/`shorter` are mechanical transforms where voice injection only risks unwanted
rewriting. Facts only matter where the model composes *new* content directed at people/projects
(`respond`, `custom`, conversation), not in tone-only transforms.

## Inference details

### Profile generation prompt (voice card + facts in one pass)
The background pass sends the model:
- **System:** an extraction instruction — produce (a) a concise voice description across fixed dimensions and
  (b) a conservative facts list; output strict JSON `{ "voice_card": "...", "facts": ["..."] }`; **do not
  invent traits or facts not evidenced in the samples**; omit facts if unsure.
- **User:** a bounded sample of recent interactions — prioritize the user's **own original text**
  (`selection`) and **edited outputs** (`edited_output`, the highest-signal corrections toward voice). Cap at
  a token budget (e.g. ~30-50 interactions or a fixed char budget, whichever first).

Voice-card dimensions (kept to *perceptible* traits): tone/register and how it shifts by context; formality;
typical sentence length & rhythm; vocabulary register + signature words to favor/avoid; punctuation & casing
habits; openings/sign-offs; emoji & emphasis; contractions/hedging/directness.

Parsing: tolerant JSON extraction; on parse failure, keep the previous profile and log (never write a garbled
card).

### Exemplar selection (per request, cheap)
`SELECT selection FROM interactions WHERE selection IS NOT NULL AND length(selection) BETWEEN 20 AND 1200
ORDER BY RANDOM() LIMIT 5` (recency-weighting is an acceptable alternative; **topical/embedding similarity is
explicitly excluded** — it degrades voice). De-duplicate near-identical samples. If fewer than ~3 qualifying
samples exist, inject what's available or none.

### Thresholds (cold-start + freshness)
- **Cold-start gate:** no voice card is generated or injected until `interactions` count ≥ **15**. Below that,
  generation runs with base prompt + (if ≥3 exist) exemplars only — never a card hallucinated from sparse data.
- **Regenerate** when `interactions` count ≥ `1.5 × sample_count` (≈50% growth) since last generation, OR on
  explicit "Regenerate now."
- **Single-flight:** `maybeRegenerate()` no-ops if a generation is already running.

### Regeneration vs. user edits
If `user_edited = 1`, automatic regeneration is **suppressed** (the user's hand-tuned card is ground truth);
only explicit "Regenerate now" overwrites it (and clears the flag). This prevents the background pass from
silently undoing a correction the user made specifically to fix a wrong trait.

## Data flow

```
interaction accepted/saved (PanelController → Persistence.save)
        │
        └─> MemoryService.maybeRegenerate()         [fire-and-forget, single-flight]
                 │  count ≥ 15 AND count ≥ 1.5×sample_count AND !user_edited
                 └─> generateProfile()  ──(background llama.cpp call)──> parse JSON
                        └─> Persistence upsert style_profile; refresh cache

generation requested (one-shot :589 / conversation :740)
        │
        └─> MemoryService.compose(base:for:)
                 ├─ base system prompt (registry / conversationSystem)
                 ├─ + voice card        (if action eligible AND card != nil)
                 ├─ + facts             (if action eligible AND non-empty)
                 └─ + 3-5 exemplars     (if action eligible; cheap SQL, diversity-selected)
        └─> StreamingClient.complete(...)  [unchanged]
```

## Error handling
- Model error during `generateProfile()` → keep previous profile, log, no user-visible failure.
- JSON parse failure → same (never persist a garbled card).
- Empty/absent profile → generation proceeds with base prompt (+ exemplars if available); the feature
  degrades to today's behavior, never blocks.
- Exemplar query failure → inject no exemplars; proceed.

## Testing (logic layer, matches the repo's 22-test posture)
- **Migration:** v3 creates `style_profile`; existing data survives; single-row upsert semantics.
- **Cold-start gate:** with <15 interactions, `compose` injects no card; with ≥15 and a card present, it does.
- **Injection matrix:** `compose(base:for:)` includes/excludes card/facts/exemplars per the action table
  above (e.g. `proofread` → base only; `respond` → card+facts+exemplars).
- **Regeneration thresholds:** `maybeRegenerate` triggers at ≥1.5× growth, no-ops otherwise, no-ops when
  `user_edited`, no-ops when already running (single-flight).
- **Parse tolerance:** valid JSON → populated profile; garbled output → previous profile retained.
- **Exemplar query:** excludes NULL/too-short/too-long selections; respects LIMIT; (determinism: inject a
  seeded/ordered variant in tests rather than `RANDOM()`).
- These verify *intent* (a wrong/sparse profile must not reach a prompt; proofread must never get voice),
  per the repo's "tests encode why" rule. View/notch surface is build + manual visual check, as established.

## Resolved decisions
1. **Inspect/edit placement** — **section in recents** (pinned "Your writing profile" row, opens inline). No
   new top-level surface. Prototype: `sketches/memory-surface-prototype.html` variant A.
2. **Facts extraction** — **on by default in v1**, with a conservative "omit if unsure" extraction prompt and
   full visibility/editability in the inspect view.
3. **Sample-budget numbers** — 15 cold-start gate / ~40-interaction generation cap are reasoned starting
   points, not measured; tune during build.
```
