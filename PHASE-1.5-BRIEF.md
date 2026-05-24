# Phase 1.5 — Conversational surface

> One-page preview. NOT a full plan. Phase 1 must ship and be used daily before this gets a real grill→design→spec→plan cycle.

## What it is

Same NSPanel from Phase 1, extended into a **persistent, multi-turn conversational surface**. Per [ADR 0001](./docs/adr/0001-phase-1-quick-action-only.md): same panel, same model plumbing, same hotkey — the panel just becomes *stateful* across turns instead of one-shot.

What ships:
- Persistent panel mode (doesn't auto-dismiss after one action).
- Free-form chat over the selection: "make it more formal", "give me three opening lines", "shorter still".
- Visible message history within the panel.
- Proactive nudges ("this email reads tense — soften?") triggered by passive observation of the source app.

What doesn't ship in 1.5:
- Memory inference (that's Phase 2 — knows your voice over time).
- Personalities / personas (Phase 3).

The latency target (<500ms hotkey-to-first-token) does NOT carry forward — response quality matters more than speed-to-first-token in conversation.

## Dependencies on Phase 1

What Phase 1 has already future-proofed (no rework when 1.5 lands):

| Phase 1 artifact | How 1.5 extends |
|---|---|
| `PanelState` enum (SWIFTUI-SPEC §6) | Add new cases: `.conversing(threadID)`, `.proactiveNudge(...)`. The enum-with-associated-values shape grows cleanly. |
| Streaming infrastructure (`StreamingClient`) | Reused as-is — multi-turn just means more requests over time. |
| Persistence schema (ADR 0006) | Add a `thread_id` column to `interactions`, plus a new `threads` table. Schema migration. |
| NSPanel + Direction A layout (DESIGN.md §3.3) | The result region grows into a scrollable thread view. Selection block stays anchored at top as conversation context. |
| Anchor store (per-bundle-ID) | Reused; persistent panel might want a separate anchor than transient. |

What Phase 1 ships that 1.5 **doesn't** depend on (so it can stay deferred):
- Memory inference output (Phase 2)
- Action prompts (1.5 conversations are free-form, not action-templated)

## Open design questions — grill these once Phase 1 ships

The right time to answer is *after you've used the slab daily for a few weeks*. Speculative answers now will be wrong.

1. **Mode transition.** How does a transient quick-action become a persistent conversation? User-explicit ("Discuss this") or auto-promote (user hits ⌫ N times in a session)?
2. **Proactive nudge trigger.** Passive AX read of the source app's text field (re-introducing a *narrow* AX read, gated per-app)? Time-based heuristic? Frequency-of-use signal? Or just: "panel sits open and the user types a question into it"?
3. **Conversation visual layout.** Replace the action menu region with a flat thread, or grow the panel taller with bubbles? Both have prior-art (Granola vs. ChatGPT).
4. **Dismiss model.** When does a persistent panel close? Esc only? Auto-dismiss after N minutes of inactivity? Sticky-until-user-pins-elsewhere?
5. **Selection lifetime.** Does the original captured selection stay anchored as the conversation's context, or fade out after the first reply?
6. **History scrollback.** How far back does the thread go visually before it scrolls / collapses?
7. **AX permission expansion.** Proactive nudges (reading passively) require an AX scope expansion. How is that re-asked? Does it gate per-app via System Settings, or globally?
8. **Conversation persistence.** Does each conversation persist to the threads table (resumable next day), or are conversations session-only?
9. **Inter-action transitions inside a conversation.** Can the user invoke a fixed action mid-conversation ("Now make it shorter") as a one-liner, or is everything free-form once you're in conversational mode?
10. **Latency posture.** What's the new perf target? Time-to-first-token still matters but is less rigid. Time-to-coherent-reply might be the new gate.

## Things to deliberately NOT pre-commit

- The chat UI specifics. Build Phase 1 first, see how the panel actually gets used, design 1.5 from contact with reality.
- The proactive-nudge trigger. The hardest piece — wrong-feeling nudges are worse than no nudges. Save the design call for *after* you have user feel for what's annoying.
- SQLite schema extensions. The `thread_id` column is obvious; the rest depends on the proactive-nudge + persistence answers above.
- Anything that crosses into memory inference. That's Phase 2's job; keep 1.5 purely about the conversation surface, not about learning anything.

## When this brief unblocks

Trigger to start the real planning cycle (grill → impeccable → swiftui-expert → PLAN):

- Phase 1 `.dmg` is in users' hands (M8 done).
- You've personally used Phase 1 for >7 daily-use days.
- At least 3 beta users have given feedback on what's missing.

Until then, Phase 1.5 is on hold and this brief is the only artifact. Don't elaborate it speculatively.
