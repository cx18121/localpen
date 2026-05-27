# ADR 0010 — Conversational surface: follow-up entry, paired-bubble threads, resumable persistence

**Status:** Accepted; extends [ADR 0001](./0001-phase-1-quick-action-only.md)
**Date:** 2026-05-27
**Extends:** ADR 0001 — Phase 1 ships quick-action only; conversational surface deferred to Phase 1.5
**Confirms (does not reverse):** [ADR 0003](./0003-clipboard-mediated-text-io.md) — clipboard-mediated text I/O, no AX tree-walking

## Context

ADR 0001 deferred the conversational surface to Phase 1.5, built on the same NSPanel and model plumbing as the quick-action surface, with an explicit constraint: the Phase 1 one-shot fast loop must not regress. Phase 1.5 now builds that surface. This ADR records the locked design decisions (from the 2026-05-27 conversational-surface design brainstorm) so they are not relitigated.

The questions to settle: how does a user *enter* a conversation; how is the thread laid out; do threads persist and resume; how does the user "nudge" a refinement; and does any of this touch the ADR 0003 no-passive-accessibility-observation boundary.

## Decision

1. **Entry via a follow-up box that promotes a one-shot result into a thread.** A reply box renders below the one-shot `.result`. Typing a follow-up + Return calls `promoteToConversation(followUp:)`, which seeds a `Conversation` (`[user(seed action), assistant(result), user(follow-up)]`) and transitions to `.conversing`. The quick-action one-shot remains the default; the fast loop is untouched. The result reply box is **not** auto-focused (`autoFocus: false`), so the result's existing keyboard handling (Return = accept, ⌘C = copy, Tab = edit, Esc = back) is unaffected until the user clicks into the box. There is no separate "Discuss" action and no chat-by-default mode.

2. **Paired-bubble thread layout.** Both sides are filled, asymmetric, borderless: assistant replies lead in neutral grey (`panelBG2`) with a bottom-leading tail; user turns trail in faint `accentTint` with a bottom-trailing tail. The seeding action renders as a small quiet pill chip, not a sentence.

3. **Resumable threads.** A new `threads` table plus a nullable `thread_id` column on `interactions`. Each conversation turn is an `interaction` row tagged with `thread_id` — turns reuse the existing table (DRY, consistent with ADR 0006); a thread is its rows replayed in timestamp order. An always-available history control in the panel chrome opens a recent-threads list; selecting one resumes it (`resumeThread`). One-shot interactions keep `thread_id = NULL` and are unaffected.

4. **In-panel refinement chips (fixed set) as the nudge mechanism.** After the latest assistant reply, a fixed chip row (Soften / Tighten / More formal / More casual) offers one-tap refinements; tapping sends the label as a follow-up. **ADR 0003 is unaffected:** nudges are entirely in-panel, triggered by what the user already brought into the panel. There is no passive accessibility observation of the user's other apps and no AX tree-walking. This ADR records that ADR 0003 holds rather than reversing it.

This ADR extends ADR 0001: it fills in the Phase 1.5 conversational surface that ADR 0001 named but deferred, on the same panel and state machine.

## Alternatives considered

1. **Explicit "Discuss" action in the menu.** Rejected — adds a menu row and a mode switch for what is naturally a follow-up to a result; the follow-up box is lower-friction and keeps the one-shot the default.
2. **Chat-by-default (panel opens as a conversation).** Rejected — regresses the sub-500ms one-shot fast loop that ADR 0001 protects; conversation is opt-in via a follow-up.
3. **Ephemeral (non-resumable) threads.** Rejected as the default — losing a refinement thread on dismiss is a daily-use papercut; threads persist. (Ephemeral remains the *fallback* when persistence is unavailable — see Consequences.)
4. **Passive-AX proactive nudges (observe the user's typing across apps).** Rejected — violates ADR 0003's clipboard-only, no-tree-walking boundary; nudges stay in-panel.
5. **Model-driven nudge detection ("this reads tense, want to soften it?").** Deferred — v1 chips are a fixed set; genuine model-detected nudges are out of scope for Phase 1.5.
6. **Inline-transcript layout (no bubbles, role-prefixed lines).** Rejected in favor of paired bubbles — bubbles make turn ownership and the asymmetric assistant/user roles legible at a glance.

## Consequences

- **Schema v2 migration.** An additive GRDB migration (`threads` table + nullable `interactions.thread_id`). Existing one-shot rows are unaffected (`thread_id` stays NULL).
- **Conversation works in-memory if persistence is unavailable.** A nil `ConversationStore` or a failed `createThread` yields an ephemeral thread (`threadID = -1`): the conversation runs in-session but is not saved and cannot be resumed. Persistence failure never blocks the conversation or orphans the result.
- **No inter-token watchdog on conversation turns yet.** The one-shot streaming watchdog is not yet armed on conversation turns; a stalled turn surfaces via cancellation/dismiss rather than a timeout. Deferred.
- **Model-driven nudge detection deferred.** The chip set is fixed in v1; adding model-detected refinement suggestions is future work.
- **ReplyBox is shared.** Extracted to `ReplyBox.swift` and used by both `ConversationView` (`autoFocus: true`) and the one-shot result view (`autoFocus: false`); no duplication.
