# ADR 0001 — Phase 1 ships the quick-action surface only; conversational surface is Phase 1.5

**Status:** Accepted
**Date:** 2026-05-23

## Context

The PRD originally described two interaction modes "sharing the same surface": a *conversational* primary mode (persistent panel, multi-turn chat, proactive nudges) and a *hotkey-triggered quick-action* secondary mode (transient, one-shot, sub-500ms). Phase 1's table row, however, named only "floating panel + 6 actions + 1 curated local model" and set a latency target (<500ms hotkey-to-first-token) that only makes sense for the quick-action mode. The product description and the Phase 1 deliverables contradicted each other.

These are different products that happen to share an NSPanel:

- **Quick-action** is stateless. Hotkey → action menu → stream result → paste back → dismiss. The user is editing in the source app and never leaves it.
- **Conversational** is stateful. Multi-turn, scrollable history, proactive trigger logic, free-form input. The user is having a side conversation about their writing.

Building both well in Phase 1 doubles the scope. Conversational mode requires solving message history, context-window management, scroll/thread UI, proactive trigger logic, and inline suggestion rendering — each Phase-sized in its own right.

The earlier UI prototype validated "Variant A — Conversation". The right read of that validation is "we know conversation is the long-term shape," not "build conversation first."

## Decision

**Phase 1 ships the quick-action surface only.** The conversational surface is deferred to **Phase 1.5**, built on top of the same NSPanel and the same model plumbing.

The Phase 1 wedge against Apple Writing Tools is *not* conversation — Apple doesn't have conversation either. The wedge is **app coverage** (works in Slack, Cursor, Discord, Gmail-in-Chrome — Apple's tools don't) + **bigger models** + **ownership**. That's enough to launch.

Architecturally, the quick-action surface must be built in a way that does not preclude the conversational surface — single NSPanel, single state machine extensible to multi-turn, streaming infrastructure reusable, etc.

## Alternatives considered

1. **Ship both in Phase 1, conversation primary.** Honors the original product-shape claim but ~2× the scope. Risks shipping neither surface polished, which violates the "interface quality is the gate" principle.
2. **Ship conversation only in Phase 1, no hotkey.** Closer to the prototype, but loses the latency story and the Apple-Writing-Tools-parity-in-every-app pitch — leaves the most-cited daily pain (the ChatGPT shuttle for one-off rewrites) unaddressed.
3. **Ship both as separate disconnected modes.** Two panels, two state machines. Easier individually, but commits to a fork in code and contradicts the "same surface" promise of the PRD.

## Consequences

- The PRD's *Product shape* section is rewritten to describe two **surfaces** shipped in stages, not two simultaneous modes.
- The Phasing table gains a Phase 1.5 row for the conversational surface.
- The Phase 1 success metric remains <500ms hotkey-to-first-token — that's the quick-action target and it now matches the deliverable.
- The Phase 1 architecture must keep the door open to multi-turn: state machine that can grow, streaming pipe that can drive a chat view, panel that can be re-styled persistent. No shortcuts that lock us into one-shot.
- Marketing and demo narrative for Phase 1 leads with "every-app + ownership", not with "your AI writing partner". The latter waits until 1.5.
