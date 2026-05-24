# ADR 0006 — Persist every interaction from day 1; minimal SQLite schema

**Status:** Accepted
**Date:** 2026-05-24

## Context

Phase 2 of the roadmap is **Memory** — the companion learns the user's writing voice over time. Inference for that memory is deferred to Phase 2 by definition. The question for Phase 1 is whether to *collect* the data that Phase 2 will eventually infer from, or to defer collection until Phase 2 ships.

Two architectural shapes:

- **Fire-and-forget Phase 1.** No persistence between hotkey invocations. Stateless. Phase 2 adds the entire persistence layer when memory ships.
- **Persist from day 1.** Phase 1 logs every interaction to local SQLite even though Phase 1 itself doesn't read the log. Phase 2 turns on memory by adding the read + inference layer on top of pre-existing data.

The trade-off is asymmetric: cost-to-persist is trivial (one table, one INSERT per interaction, no UI), benefit is significant (no cold-start for users when Phase 2 ships). The user has noted that Phases 1, 1.5, 2 will land within days of each other, so cold-start risk is small in absolute terms — but the cost of persisting is also small, so the asymmetry still favors persistence.

## Decision

**Persist every Phase 1 interaction to local SQLite from day 1.**

Schema (minimal but complete for Phase 2's plausible needs):

```sql
CREATE TABLE interactions (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp       INTEGER NOT NULL,        -- unix epoch seconds
  source_app      TEXT,                    -- bundle ID of frontmost app at hotkey time
  selection       TEXT,                    -- captured text
  action          TEXT NOT NULL,           -- 'proofread' | 'polish' | 'more_formal' | 'more_casual' | 'shorter' | 'custom'
  custom_prompt   TEXT,                    -- only populated when action = 'custom'
  model_id        TEXT NOT NULL,           -- e.g. 'qwen-2.5-7b-instruct-q4-km'
  model_output    TEXT,                    -- final streamed result
  accepted        INTEGER NOT NULL,        -- 0 / 1
  edited_output   TEXT                     -- populated only if user edited the result before accepting
);
```

File location: `~/Library/Application Support/Localpen/history.sqlite`. Owned by the user, never leaves the machine, no telemetry.

What Phase 2 can infer from this schema:
- Action-frequency distribution (which actions does the user reach for?)
- Rejection patterns (`accepted = 0` rows reveal where the model disagreed with the user's intent)
- User's actual voice as deltas (`edited_output` minus `model_output` is voice-in-delta-form)
- Per-app tone (`source_app` lets Phase 2 learn that the user writes differently in Slack vs. Mail)

## Alternatives considered

1. **Fire-and-forget Phase 1.** Lower complexity. Rejected: even if Phase 2 ships days later, persisting from day 1 has effectively no cost.
2. **Richer schema (separate tables for selection, prompts, outputs).** Normalized design. Rejected for Phase 1: premature. The interactions table is the read pattern; normalization can come if Phase 2 needs it.
3. **In-memory only with periodic disk snapshot.** Trades durability for speed. Rejected: SQLite is fast enough that the speed argument doesn't apply; durability matters because losing history defeats the purpose.
4. **Encrypted at rest.** Rejected for Phase 1: same threat model as Notes.app or Mail.app local stores; FileVault covers most users. Revisit in Phase 3 when audience widens to non-technical users.

## Consequences

- **First-run flow includes a one-line transparency disclosure**: "Localpen saves your interactions locally so it can learn your style over time. Your data never leaves this Mac." Non-blocking, design-phase decides exact placement.
- **Power User affordances exposed in Phase 1**: "clear history" and "export history (JSON)". Both operate on the same SQLite file.
- **Phase 1.5 conversation schema extends this table** (add `thread_id` column or join to a new `threads` table). Not designed yet — deferred to Phase 1.5 work.
- **Phase 2 memory tables (e.g. `inferred_style`) layer alongside this table.** No backward-incompatible changes to `interactions` expected.
- **No cross-device sync, ever.** Per local-first principle. The SQLite file is per-machine.
- **Worst-case storage growth is small** (100 interactions/day × 365 days × ~2 KB/row ≈ 70 MB). Negligible on any modern Mac.
