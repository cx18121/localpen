# Memory (sub-project A) — Design Spec

**Date:** 2026-05-27
**Roadmap:** [ROADMAP.md](../../../ROADMAP.md) sub-project **A**. First step toward the local-assistant north star; also directly improves the writing tool already shipped.
**Status:** Design — revised after Codex adversarial review (authored-text attribution, post-commit hook,
seed-action conversation gating, durable forget). Awaiting user review before planning.

---

## Goal

Localpen learns the user's writing **voice** and a small set of **facts** about them, implicitly from
persisted interactions, and conditions generation on them — so rewrites and replies sound like the user
wrote them, without the user ever managing a memory UI. A lightweight inspect/edit view exists as a safety
valve, not a chore.

This is a **single-user, local** feature: the model is already running (llama.cpp), and every interaction
is already persisted to SQLite ([ADR 0006](../../../docs/adr/0006-persist-interactions-from-day-1.md)). No
network, no embeddings pipeline, no new SPM dependency.

## Authored-text attribution (read first — failure mode if wrong)

The spec was originally built on the assumption that `interactions.selection` is *the user's own
writing*. **It isn't, uniformly** — and getting this wrong would train the voice profile on third-party
text and silently inject it into every future rewrite. Codex review caught this; the attribution rules
below are now load-bearing.

Per-action authored-text policy (what counts as a *user voice sample*):

| Action | `selection` is… | User-voice sample source |
|---|---|---|
| `proofread`, `polish`, `moreFormal`, `moreCasual`, `shorter` | the user's own text being transformed | **`selection`** (✓ user voice) |
| `custom` (one-shot) | the user's own text (or empty); `customPrompt` = the user's instruction | **`selection`** (if non-empty) and **`customPrompt`** as evidence of how the user phrases requests |
| `respond` | a **third-party message** the user is replying to — *not* user voice | **NEVER `selection`.** Use `editedOutput` if accepted; `customPrompt` (the user's steer phrasing) as weak signal |
| conversation (rows where `threadID` is not null) | always `nil` on the row (per `ConversationStore.swift:57,76`); the seed selection lives in `threads.original_selection` (only user voice if seed action isn't `.respond`) | **`customPrompt`** (the user's follow-up message) is the primary sample; `threads.original_selection` only when the seed action is in the "selection-is-user-text" set above |
| any action | the user's hand correction `editedOutput` (when `accepted = 1` and `editedOutput` differs from `modelOutput`) | **highest-signal** user voice — always eligible regardless of action |

`facts` extraction uses the same allowlist (third-party message content in `respond.selection` must never
become a "fact about the user").

This attribution table is the contract `MemoryService` must enforce in *both* exemplar selection and the
inputs fed to profile generation.

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
- `sampleCount: Int` — number of *eligible* (per authored-text attribution) interactions the current profile
  was built from. Drives regeneration threshold and the cold-start gate.
- `userEdited: Bool` — set when the user hand-edits the card/facts; see "Regeneration vs. user edits."
- `forgottenBefore: Int64` — unix epoch tombstone (default 0). Profile generation and exemplar selection
  ignore any interaction row with `timestamp < forgottenBefore`. "Forget everything" sets this to `now()`
  (see Inspect/edit), making forget **durable** — the next regeneration cannot resurrect a forgotten card
  from pre-forget history.

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
| `forgotten_before` | INTEGER | not null, default 0 (unix epoch tombstone for durable Forget) |

### 3. `MemoryService` (new, `@MainActor`)
The seam. Owns profile lifecycle and prompt composition. Depends on `Persistence` (read interactions, R/W
profile) and `StreamingClient` (background generation).

Responsibilities:
- **`profile() -> StyleProfile`** — load the current profile (cached in memory; refreshed after generation).
- **`interactionDidPersist()`** — **post-commit hook**, called *after* a durable write of a user interaction
  row (one-shot accept/reject, or conversation turn). Decides (cheaply, see thresholds) whether to kick a
  background generation. Single-flight: never two generations at once. See "Post-commit wiring" below.
- **`generateProfile()`** — the background pass: pull a sample of *eligible* (per authored-text attribution
  + `forgottenBefore`) recent rows, build the summarization prompt, stream a completion from the local
  model, parse it into `voiceCard` + `facts`, persist. Does **not** block any user-facing generation. Skips
  silently on model error (keeps last profile).
- **`compose(base: String, for action: Action, seedAction: Action? = nil) -> String`** — returns the
  action-gated system prompt to send to the model (see Injection). Pure/sync: reads cached profile + does
  one cheap SQL pull for exemplars. `seedAction` is supplied by the conversation entry point so a
  proofread-seeded thread doesn't get voice/facts/exemplars even on a follow-up turn.

### 3a. Post-commit wiring (load-bearing — write-path audit caught this)
The app has **two** durable-write paths for user-authored data, and they do **not** share a single API:

- **One-shot interactions** — `PanelController.persistInteraction` fires `Task.detached { await
  persistence.save(interaction) }` (no completion callback today).
- **Conversation turns** — `ConversationStore.createThreadWithSeed` and `ConversationStore.appendExchange`
  write directly to the GRDB queue, bypassing `Persistence.save`.

A hook installed only at the `PanelController` level would race the detached one-shot insert and **miss
conversation rows entirely.** The hook must run *after* the durable write, on both paths. Two acceptable
shapes (planning chooses one):

1. **Post-commit closure on each write site** — `Persistence.save(_ :)` accepts (or wraps) a completion
   that runs after the GRDB transaction commits; `ConversationStore`'s two write methods accept the same.
   `AppDelegate` injects a closure that calls `memory.interactionDidPersist()`.
2. **`NotificationCenter` post** — `Persistence.save` and the two `ConversationStore` write paths post a
   single `localpen.interactionPersisted` notification after commit. `MemoryService` subscribes.

Either is fine; the spec's contract is: **every durable user-authored row, from either path, triggers
exactly one `interactionDidPersist()` after commit.** This is testable independently of `MemoryService`.

### 4. Injection composition (integration into `PanelController`)
Two existing generation entry points compose the preamble; **`registry.systemPrompt(for:)` is the base** and
memory wraps it (the static `ActionPrompts.styleContext` global is *not* sufficient — the registry path can
bypass it, so injection happens at the call site):

- One-shot — `PanelController.swift:589`: `let systemPrompt = registry.systemPrompt(for: action)` becomes
  `let systemPrompt = memory.compose(base: registry.systemPrompt(for: action), for: action)`.
- Conversation — `PanelController.swift:740`: the `("system", ActionPrompts.conversationSystem)` message
  becomes `("system", memory.compose(base: ActionPrompts.conversationSystem, for: .custom, seedAction:
  convo.turns.first?.action))`. **Conversation gating uses the seed action**, not blanket `.custom`: a
  thread seeded by `proofread` or `shorter` keeps the mechanical-transform invariant on every follow-up turn
  (no card, no facts, no exemplars), because the user is still iterating on a no-drift refinement, not
  asking for new content. The conversation entry point therefore looks up `Conversation.turns.first?.action`
  and passes it as `seedAction`.

`compose(base:for:seedAction:)` assembles, in order: `base` system prompt → (if eligible per the injection
matrix, using `seedAction ?? action`) voice card → (if eligible) facts → (if eligible) exemplars block.
Exemplars are injected in the **system** prompt as labeled samples ("Here are samples of how the user
writes:\n---\n…"), not as fake user turns.

### 5. Inspect/edit surface (reached from recents)
**Placement (decided): a pinned "Your writing profile" row at the top of the existing recents/thread list**,
which opens the profile inline (no new top-level surface; minimal state-machine wiring). Visual prototype:
`sketches/memory-surface-prototype.html` (variant A). The opened view shows:
- The voice card — multi-line, freely **editable** text.
- The facts list — **editable** bullets, add/remove.
- "Regenerate now" and **"Forget everything" — durable**: clears `voice_card` + `facts` *and* sets
  `forgotten_before = now()` so all pre-forget interactions are permanently excluded from future profile
  generation and exemplar selection. (`interactions` rows are not deleted — distinct from "Clear history" —
  but they can no longer feed memory.) This closes the loophole where clearing just the profile would let
  the next regeneration rebuild the same card/facts from the same source rows.
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
| conversation | follows **seed action** | follows **seed action** | follows **seed action** |

Rationale: `proofread`/`shorter` are mechanical transforms where voice injection only risks unwanted
rewriting. Facts only matter where the model composes *new* content directed at people/projects
(`respond`, `custom`, conversation), not in tone-only transforms. Conversation inherits the seed-action's
row in this matrix — a proofread-seeded thread never gets voice/facts/exemplars even on follow-up turns.

## Inference details

### Profile generation prompt (voice card + facts in one pass)
The background pass sends the model:
- **System:** an extraction instruction — produce (a) a concise voice description across fixed dimensions and
  (b) a conservative facts list; output strict JSON `{ "voice_card": "...", "facts": ["..."] }`; **do not
  invent traits or facts not evidenced in the samples**; omit facts if unsure.
- **User:** a bounded sample of *eligible* recent interactions, filtered through the **Authored-text
  attribution** table above (e.g. for `respond` rows, send `edited_output` and `custom_prompt`, *never*
  `selection`; for conversation rows, send `custom_prompt`; only include rows with `timestamp >=
  forgottenBefore`). Prioritize the highest-signal source per row: `editedOutput` first when present,
  then the row's action-specific user-voice source. Cap at a token budget (e.g. ~30-50 eligible rows or a
  fixed char budget, whichever first).

Voice-card dimensions (kept to *perceptible* traits): tone/register and how it shifts by context; formality;
typical sentence length & rhythm; vocabulary register + signature words to favor/avoid; punctuation & casing
habits; openings/sign-offs; emoji & emphasis; contractions/hedging/directness.

Parsing: tolerant JSON extraction; on parse failure, keep the previous profile and log (never write a garbled
card).

### Exemplar selection (per request, cheap)
A single query that respects the authored-text attribution and the forget tombstone. Conceptually:

```sql
-- "user voice sample" is action-conditional. proofread/polish/moreFormal/moreCasual/shorter/custom use
-- selection; respond uses edited_output (not selection — third-party content); conversation rows use
-- custom_prompt. Any action with a non-empty edited_output is highest-signal regardless of action.
SELECT
  CASE
    WHEN edited_output IS NOT NULL AND length(edited_output) >= 20 THEN edited_output
    WHEN action = 'respond'                                        THEN edited_output   -- never selection
    WHEN thread_id IS NOT NULL                                     THEN custom_prompt
    ELSE selection
  END AS sample
FROM interactions
WHERE timestamp >= :forgottenBefore
  AND sample IS NOT NULL
  AND length(sample) BETWEEN 20 AND 1200
ORDER BY RANDOM()
LIMIT 5;
```

Recency-weighting is an acceptable alternative; **topical/embedding similarity is explicitly excluded** — it
degrades voice. De-duplicate near-identical samples. If fewer than ~3 qualifying samples exist, inject what's
available or none. Tests pass an ordered (non-random) variant for determinism.

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
durable user-authored row written (one-shot Persistence.save  OR  ConversationStore.{createThreadWithSeed,appendExchange})
        │
        └─> post-commit hook fires once per row
                  │
                  └─> MemoryService.interactionDidPersist()      [single-flight]
                         │  eligibleCount ≥ 15 AND eligibleCount ≥ 1.5×sample_count
                         │  AND !user_edited AND no generation in flight
                         └─> generateProfile()  ──(background llama.cpp call)──> parse JSON
                                └─> upsert style_profile; refresh cache

generation requested
        │
        ├─ one-shot (PanelController :589):
        │     compose(base: registry.systemPrompt(for: action), for: action, seedAction: nil)
        │
        └─ conversation (PanelController :740):
              compose(base: ActionPrompts.conversationSystem,
                      for:  .custom,
                      seedAction: convo.turns.first?.action)
                  ├─ resolves gating action = seedAction ?? for
                  ├─ + voice card    (if gating-action eligible AND card != nil)
                  ├─ + facts         (if gating-action eligible AND non-empty)
                  └─ + 3-5 exemplars (if gating-action eligible; per-action attribution SQL above)
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
- **Cold-start gate:** with <15 eligible interactions, `compose` injects no card; with ≥15 and a card
  present, it does.
- **Injection matrix:** `compose(base:for:seedAction:)` includes/excludes card/facts/exemplars per the
  action table — `proofread` → base only; `respond` → card+facts+exemplars; conversation seeded by
  `proofread` → base only even on follow-up turns (regression test the seed-action carry-through).
- **Authored-text attribution:** profile-generation input and exemplar query both
  *exclude* `respond.selection`; for conversation rows (`thread_id != NULL`) they use `custom_prompt`,
  not `selection`. (Direct regression for the Codex-caught failure mode.)
- **Durable forget:** "Forget everything" sets `forgotten_before = now()`; after that, profile
  regeneration on the *same* historical rows produces an empty card/facts (no resurrection of forgotten
  content). Exemplar query likewise returns zero pre-forget samples.
- **Post-commit hook coverage:** every durable write — one-shot `Persistence.save`, conversation
  `createThreadWithSeed`, conversation `appendExchange` — fires `interactionDidPersist()` exactly once
  after commit. Test each write path independently.
- **Regeneration thresholds:** `interactionDidPersist` triggers `generateProfile` at ≥1.5× growth, no-ops
  otherwise, no-ops when `user_edited`, no-ops when already running (single-flight).
- **Parse tolerance:** valid JSON → populated profile; garbled output → previous profile retained.
- **Exemplar query:** excludes NULL/too-short/too-long samples; respects LIMIT; honors `forgotten_before`;
  applies the per-action sample mapping (determinism: inject a seeded/ordered variant in tests rather than
  `RANDOM()`).
- These verify *intent* (a wrong/sparse profile must not reach a prompt; proofread must never get voice;
  third-party text from `respond.selection` must never become user voice; forget must be durable), per the
  repo's "tests encode why" rule. View/notch surface is build + manual visual check, as established.

## Resolved decisions
1. **Inspect/edit placement** — **section in recents** (pinned "Your writing profile" row, opens inline). No
   new top-level surface. Prototype: `sketches/memory-surface-prototype.html` variant A.
2. **Facts extraction** — **on by default in v1**, with a conservative "omit if unsure" extraction prompt and
   full visibility/editability in the inspect view.
3. **Sample-budget numbers** — 15 cold-start gate / ~40-interaction generation cap are reasoned starting
   points, not measured; tune during build.
```
