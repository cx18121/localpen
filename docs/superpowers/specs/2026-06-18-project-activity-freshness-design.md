# Project Activity Freshness — Design Spec

**Date:** 2026-06-18
**Status:** Design (pre-implementation)
**Relates to:** [ADR 0015](../../../docs/adr/0015-autonomous-curation-discipline.md) (dream cycle / curation), [ADR 0024](../../../docs/adr/0024-hub-reduced-to-four-modes.md) (hub declutter). Enables a future **orient panel** sub-project (separate spec).

---

## 1. Problem

The app reads a brain that's quietly rotting. Project pages (`projects/*.md`) go stale because:

1. **Progress lives in work artifacts the brain can't see** — chiefly git commits, the actual log of what the user did.
2. **Hand-updating notes is a no-payoff chore** that loses to real work.

Stale project pages undermine *everything* brain-grounded: the W2 grounded writing reads drifting notes, and any "orient / what's hot" surface would brief from fiction. The user commits frequently and writes disciplined conventional commits (`feat(w2): …`, `fix(hub): …`) with real bodies, so the progress signal already exists in high-quality form; it just never reaches the page.

**Fix the freshness and the brain becomes trustworthy again. This spec is that freshness pipeline.**

## 2. What this is / is not

- **Is:** a nightly pass that reads each project's git commits, summarizes them into an honest dated rollup, and appends to a tool-owned `## Activity` log on the project page. Zero user friction; auto-write.
- **Is not:** the **orient panel** (surfacing the fresh brain + acting) — that's the next sub-project, enabled by this.
- **Is not:** a rewrite of hand-curated content. The pass only ever *appends* to `## Activity`; it never touches the body, `## Status`, or frontmatter.
- **Is not:** a new scheduler, model, or capture mechanism. It rides the existing `DreamCycle` / `DreamCycleRunner`, the live transform model, and `VaultWriter`.

## 3. Trust decision

**Auto-write to an append-only Activity log** (not a review queue). The user wants zero friction, and an additive, clearly-AI-authored, dated log makes a bad entry a one-line fix rather than damage, so supervision isn't needed. Accuracy comes from good input + extractive prompting + a self-check pass (§6), not a human gate. Low-confidence routing (a review path) is explicitly rejected: it reintroduces the chore and leans on unreliable local-model self-confidence.

## 4. Architecture

A **project-activity pass** inside the nightly dream cycle. For each project page whose frontmatter `local_path` resolves to a real git repo:

1. **`GitActivityReader`** — shells `git log` for commits in the lookback window; parses each into a structured commit; filters merges + trivia.
2. **Adaptive batching** (pure) — groups commits into bounded batches (§5).
3. **Scope clustering** (pure) — within a batch, group commits by conventional-commit scope.
4. **`ProjectActivitySynthesis`** — one model call per batch (extractive, cited) + one self-check call (§6), via the existing dream-cycle synthesize closure.
5. **`CurationWrite.appendActivity`** — `VaultWriter` appends the dated entry to `## Activity` (auto-applied, additive); the vault auto-commits.

**It is a sibling pass, not nested in `DreamCycle.run()`.** The conversation dream cycle (synthesizing AI chats) and this project-activity pass are independent; the same nightly trigger that invokes `DreamCycleRunner` also invokes `projectActivityPass`, and both share the runner's temp-0.3 synthesize closure over the live llama-server. Keeping them separate means a change to one can't break the other, and the activity pass has no dependency on there being stashed conversations to curate.

Each repo is independent: a missing/moved/broken repo is skipped and logged, never errors the pass; a repo with no new commits is a no-op.

### Reused infrastructure

- `BrainIndex.pages(ofType: .project)` — enumerate project pages.
- Project frontmatter `local_path` — repo discovery (no `ProjectMatcher` name-matching needed; the page *is* the source of truth).
- `DreamCycle` / `DreamCycleRunner` — the nightly runner + the temp-0.3 synthesize closure over the live llama-server.
- `VaultWriter` — additive append + vault auto-commit (new `appendActivity` case, sibling to `appendTimeline`).

### New components

- `GitActivityReader` — git log → `[Commit]` (parse + filter).
- `ProjectActivityBatcher` — `[Commit]` → `[Batch]` (adaptive).
- `ProjectActivitySynthesis` — `Batch` → entry text (prompt assembly; calls the injected synthesize closure).
- `ProjectSyncStore` — sidecar (app-support) repo path → last-synced SHA.
- `CurationWrite.appendActivity` + its `VaultWriter` handling.
- A `projectActivityPass` orchestrator — a sibling to the conversation dream cycle, invoked by the same nightly trigger and sharing the synthesize closure.

## 5. Windowing & adaptive batching

**First run (no recorded SHA):** anchor the lookback to the page's `updated` frontmatter date — exactly "where the page went stale" — capped at **90 days** for pathologically old pages. **Steady-state:** `git log <lastSHA>..HEAD`.

**Batching is by activity, not the calendar.** Walking commits oldest→newest, a batch closes at whichever comes first: **~30 commits or ~2 weeks**. Consequences:

- **Empty stretch** → no commits → no batch → no entry (the log skips it).
- **Heavy period** → 30-commit cap fires mid-window → multiple bounded entries, each accurate instead of one 80-commit blob.
- **Sparse period** → 2-week cap fires → a light entry every ~2 weeks so the timeline isn't lumped.

Each closed batch becomes one dated entry labeled by its *actual* commit-date span (e.g. `Jun 5–6`, `May 12–24`). A batch that is all-trivia after filtering is dropped.

## 6. Summarization pipeline (accuracy core)

Per batch:

1. **Parse — no model.** Each commit → `{type, scope, subject, body (≤~300 chars), diffstat}` from `git log`. Drop merge commits and `chore/style/build` types. All-trivia batch ⇒ dropped.
2. **Cluster by scope — no model.** Group by conventional-commit scope (`w2`, `hub`, `brain`); unscoped → `other`. Attach a per-group diffstat aggregate ("w2: 12 commits, 8 files") for scale.
3. **Synthesize — one model call per batch.** The clustered commits go to the dream-cycle closure (temp 0.3) with a strict extractive prompt: *summarize only what the commit messages state; do not infer outcomes/status/progress beyond them; keep the groups; each bullet cites the short-SHAs it covers.* Output shape: `- **w2**: shipped X, fixed Y (a1b2c3, d4e5f6)`.
4. **Self-check — one cheap model call.** *Remove any clause not directly supported by a commit message below.* The corrected text is the entry.

No full-diff reading; messages + diffstat suffice given commit discipline. Citing SHAs makes the summary extractive, not generative — it cannot claim a feature absent from the log.

## 7. Page format & write path

Entries land in a **tool-owned `## Activity`** block, newest-first:

```markdown
## Activity
### Jun 5–6
- **w2**: shipped autocomplete + custom dropdown (fb7827b, d43d337)
- **hub**: reduced to 4 modes (a8c7cec)
### May 12–24
- **dotfiles**: minor tweaks (…)
```

- **Absent section** → created (appended after the body). **Present** → new dated entry prepended directly under the `## Activity` header.
- Everything from `## Activity` to the next `##` is tool-owned. The pass never parses or rewrites the body, `## Status`, or frontmatter. `updated` is read-only (first-run anchor only); after that the sidecar sync-SHA is authoritative, so frontmatter never churns.
- `CurationWrite.appendActivity(projectPath, entry)` → `VaultWriter.apply` (additive, auto-applied class). Vault auto-commits (`activity: Cairn Jun 5–6`).

**Idempotency.** After a successful write the sync store advances to `HEAD`; a same-day re-run finds no new commits and no-ops. Commits made later the same day become the next run's entry (a second dated entry is acceptable; no same-day coalescing in v1).

**Concurrency.** Append-only to a section the user doesn't hand-edit rarely collides with an in-flight Obsidian edit; an open file shows the entry on Obsidian's next read.

## 8. Degradation & failure isolation

- No `local_path` / not a git repo / path missing → skip page, log, continue.
- `git log` failure (detached HEAD, permissions) → skip repo, continue others.
- Embedding/transform server down → the dream cycle already degrades; the activity pass simply doesn't run that night (no partial writes).
- Synthesis failure for a batch → skip that batch's entry, advance sync only past successfully-written batches (a failed batch is retried next run).

## 9. Testing

Pure logic unit-tested with fixtures traced to real sources (Rule 5); model + shell paths integration-gated.

- **Commit parsing** (pure) — real `git log` fixtures from this repo (`feat(w2):…`); type/scope/body/diffstat extraction; merge + `chore/style` filtering.
- **Adaptive batching** (pure) — 30-commit / 2-week boundary; empty → no batch; heavy → split; sparse → time-capped; trivia-only batch dropped.
- **Scope clustering** (pure) — grouping, unscoped → `other`, diffstat aggregate.
- **First-run anchor** (pure) — lookback from `updated`, 90-day cap.
- **`appendActivity` write** — section created when absent, prepended when present; Status/body/frontmatter untouched. Against a fixture page.
- **`ProjectSyncStore`** — SHA round-trip, advance to HEAD, no-op when unchanged.
- **Prompt assembly** (pure) — the right commits/clusters/diffstat reach the synthesize prompt (content not asserted — non-deterministic model).
- **Integration (gated)** — end-to-end over a temp git repo: an entry is written citing real SHAs (mirrors the W2 backfill integration test).

## 10. Build order

1. `GitActivityReader` (parse + filter) — pure + a gated `git log` integration.
2. `ProjectActivityBatcher` (adaptive) — pure.
3. Scope clustering + prompt assembly (`ProjectActivitySynthesis`) — pure assembly; model call injected.
4. `ProjectSyncStore` — sidecar.
5. `CurationWrite.appendActivity` + `VaultWriter` handling.
6. `projectActivityPass` orchestrator + first-run anchor; wire into `DreamCycleRunner`.
7. Gated end-to-end verification over a real repo; then a live nightly run on the real vault (user-observed).

## 11. Done-when

- A night's commits across the user's projects produce honest, cited, scope-grouped `## Activity` entries on the matching pages, with zero manual action.
- Heavy days split into bounded accurate entries; quiet stretches stay terse; empty stretches produce nothing.
- The pass never modifies hand-curated content; a wrong entry is a one-line fix.
- All pure suites green; the gated integration passes with the server up; the brain stops going stale on its own.
- Unlocks the next sub-project: the **orient panel** over a brain that's finally true.
