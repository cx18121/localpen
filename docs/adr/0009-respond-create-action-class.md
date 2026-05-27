# ADR 0009 — Respond action and the revise/create operation-class distinction

**Status:** Accepted; amends [ADR 0004](./0004-v1-action-set.md)
**Date:** 2026-05-26
**Amends:** ADR 0004 — v1 action set

## Context

Phase 1 shipped a transform-only action set (Proofread / Polish / More formal / More casual / Shorter / Custom). Every action takes the captured selection as *source material* and returns a revised version of it — the output replaces the input. This is the **revise** pattern: the selection is the draft, and the result is an improved version of that draft.

A qualitatively different task arises in practice: the user captures an incoming message (an email, a Slack thread, a comment) and wants to *generate a reply*, not revise the message itself. Here the selection is a **stimulus** — the thing being replied to — and the output is a **new artifact** that did not exist in the source. Pasting the generated reply back over the captured stimulus would be wrong: the stimulus should stay where it is, and the reply belongs in a new compose window or reply thread.

This distinction cannot be handled by making Custom smarter. Custom's paste-back semantics are identical to the fixed actions', and the intent ("I want to reply to this") is not inferable from the selection text alone — a classifier call would tax the <500ms latency budget and still be wrong in ambiguous cases. The Respond capability needs its own named, discoverable action with correct output semantics.

## Decision

Introduce `Action.OperationClass { revise, create }`. Every `Action` case carries an `operationClass` property:

- **`.revise`** — the existing five transforms (Proofread, Polish, More formal, More casual, Shorter) plus Custom. Result pastes back over the source.
- **`.create`** — new actions whose output is a new artifact, not a revision. Result copies to the clipboard and does **not** paste back.

Add **Respond** as the first `.create` action. Its system prompt takes the selection as the message being responded to and generates a reply in the user's register. A `styleContext` seam is reserved in `ActionPrompts` for Phase 2 voice/style injection; it is empty in Phase 1.

The action menu groups the two classes under short section headers — **Revise** and **Create** — rendered above each group's rows. Navigation remains a single flat keyboard list (no submenus, consistent with ADR 0004's flat-menu principle). The Respond row is disabled when there is no working text to reply to (the empty-selection state, S3).

The complete Phase 1 action set is now:

**Revise**
1. Proofread
2. Polish
3. More formal
4. More casual
5. Shorter
6. Custom…

**Create**
7. Respond

Persistence: no migration required. The `action` column in the `interactions` table stores the raw action name as a string; "respond" is a new valid value. The `custom_prompt` column is reused when Respond carries a style steer (Phase 2); it is null in Phase 1.

## Alternatives considered

1. **Auto-detect operation class from the selection text.** Route to `.create` if the selection looks like an inbound message; route to `.revise` otherwise. Rejected: intent is not reliably encoded in the text itself. A classifier call adds latency against the <500ms budget. The wrong classification produces a subtly broken result (paste-back over an inbound message the user didn't write). Explicit user intent is cheaper and more correct.

2. **Fix only the Custom action.** Update Custom's prompt and paste-back behavior when the user phrases it as "reply to this." Rejected: leaves Respond undiscoverable (users won't think to phrase Custom that way), and paste-back semantics for all Custom prompts would need a runtime classification step to determine whether to paste or not — the same problem as option 1, just hidden inside Custom.

3. **Intent-first menu rebuild (input box + intent chips).** Replace the action menu with a free-form input and intent chips (Revise / Respond / Create / …). Deferred: this is a meaningful UX redesign that drifts into the conversational scope ADR 0001 reserves for Phase 1.5. The chip model is the right direction for Phase 1.5; it is too large a surface change for Phase 1's incremental action set.

## Consequences

- **Menu gains visual group headers.** The "Revise" and "Create" labels appear above their respective groups in the action menu. Keyboard navigation is unaffected — `↑↓` moves through all rows in document order, wrapping top/bottom as before.
- **Respond row is disabled in S3 (empty state).** A reply requires something to reply to. The row renders at reduced opacity and is skipped by keyboard navigation when no selection is captured.
- **`acceptResult` is operation-class-aware.** For `.revise` actions, `PanelController.acceptResult()` paste-backs via `TextIO.pasteBack(_:)` then dismisses. For `.create` actions, it copies to the clipboard and dismisses without paste-back. The result-toolbar footer hint updates accordingly: `.create` results show "⌘↩ copy reply" instead of "⌘↩ accept."
- **`styleContext` seam reserved.** `ActionPrompts.respond(styleContext:)` accepts an optional style string. Phase 1 always passes nil. Phase 2 will populate it from the inferred-voice store (ADR 0006's memory layer).
- **Future `.create` actions have a clear home.** Translate (deferred in ADR 0004), Draft (new message from bullet points), and similar generative actions slot naturally into the Create group without requiring another structural change.
- **ADR 0004's "6 items" wording is superseded.** The menu now has 7 items in two groups. The Phase 1 core transforms are unchanged.
