# DESIGN-1.5 — Conversational Surface

> Design contract for the Phase 1.5 conversational surface, written **as built** (merged 2026-05-27, ADR 0010). Extends [DESIGN.md](./DESIGN.md); inherits all of its tokens, spacing rhythm, typography, and the "almost monochrome, almost still" ethos. Only the conversation-specific surfaces are specified here.

## 1. What this surface is

The same NSPanel, made stateful. After a one-shot result, typing a follow-up promotes it into a persistent, resumable multi-turn thread. The Phase 1 quick-action loop is untouched; conversation is an emergent extension, not a separate mode. See [ADR 0010](./docs/adr/0010-conversational-surface-entry-and-threads.md) for the locked decisions and rejected alternatives.

## 2. Entry — the follow-up box

The promotion affordance is a reply field rendered **below the one-shot result** (`ReplyBox`, `autoFocus: false` in the result context). It does not steal focus: the result's fast path (Return = accept, ⌘C = copy, Tab = edit, Esc = back) stays intact until the user clicks into the field. Typing a follow-up and pressing Return promotes the result into a thread. The reply field hint strip is suppressed on the result (`showHints: false`) so it doesn't double up with the result toolbar.

## 3. Thread layout — paired bubbles

Both sides are filled, asymmetric, **borderless** (borders were the one thing that made stock bubbles feel un-Localpen):

- **Localpen (assistant):** leading-aligned; fill `Tokens.panelBG2`; `Typography.result`; insets `Spacing.bubbleInsetV` (9) × `Spacing.bubbleInsetH` (13); `UnevenRoundedRectangle` corners 14 except bottom-leading 4 (the tail); max width 86% of the 400pt panel.
- **You (free-form follow-up):** trailing-aligned; fill `Tokens.accentTint`; `Typography.menuRow`; same insets; corners 14 except bottom-trailing 4.
- **Seed action turn:** the first user turn is the action that started the thread, rendered as a small quiet **capsule chip** (`action.pillLabel`, `Tokens.textMute`, 1px `Tokens.hairline` border, transparent fill) — not a sentence, not an accent pill.
- **Accept affordance:** a quiet `Tokens.textFaint` "Use" button under each *assistant* bubble; user turns and the seed chip have none. The live streaming bubble has none until it settles.

The accent appears sparingly (your bubbles, the focus rail, the streaming caret) — consistent with the single low-chroma blue (hue 255) from DESIGN.md §2.

## 4. Pinned context + recents

- The original selection stays pinned at top via the shared `SelectionBlock` (same as the captured state), anchoring the thread's context.
- An always-available **recents control** (a quiet `clock` SF Symbol, `Tokens.textFaint`) sits top-trailing of the conversation and in `PanelFooter` for the menu states, so history is reachable from any surface.

## 5. Refinement chips

After a settled assistant reply (not streaming, no error), a row of quiet capsule chips offers preset follow-ups: **Soften · Tighten · More formal · More casual** (`Tokens.textSoft` text, `Tokens.hairline` border, transparent fill). Tapping one sends it as a follow-up. v1 is a **fixed set** — model-driven "this reads tense" detection is deliberately deferred (ADR 0010).

## 6. Reply box (conversation context)

The bottom-pinned `ReplyBox` mirrors `CustomPromptView`'s rail-field treatment: borderless `GrowingTextEditor` with a left rail (`Tokens.hairline` at rest → `Tokens.accent` focused), placeholder "reply to keep refining…", Return submits / ⇧Return newline, `KbdHint` footer (↩ send · ⇧↩ newline · esc close). In the conversation it `autoFocus`es and shows its hints; while a turn streams it dims to 0.5 opacity and is disabled (submission is gated until the turn completes).

## 7. Inline error + retry

A failed turn does not leave the thread. The error surfaces **inside** the conversation (`Tokens.accentError` text) with a Retry control; the failed user turn stays in place so retry re-streams it. The thread is never dropped to the generic error view.

## 8. Resume

Selecting a thread from the recents list reopens it in the conversation surface with its turns reconstructed and the original selection restored. Accept on a resumed thread copies to the clipboard (there is no live source-app field to paste into).

## 9. Not designed here (deliberately out of scope)

- **Model-driven nudge detection** — chips are a fixed set in v1.
- **Thread list visual depth** — the recents list is a flat title + relative-time list; no grouping, search, or previews yet.
- **Conversation-specific motion** beyond the inherited panel present/dismiss and the menu→result cross-fade. Bubble-appearance animation was not specified; if it feels abrupt in use, design it then (per DESIGN.md's "decide from contact with reality" stance).
