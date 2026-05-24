# ADR 0004 — v1 action set: Proofread / Polish / More formal / More casual / Shorter + Custom

**Status:** Accepted
**Date:** 2026-05-24

## Context

The Phase 1 quick-action surface presents the user with a menu of pre-defined transformations to apply to their selection. The earlier UI prototype shipped six actions: **Rewrite / Polish / Shorten / Expand / Translate / Custom**. This set needs to be locked before design (impeccable) and implementation work begins.

Pressure-testing the prototype set against the Phase 1 wedge (works in every app, parity with Apple Writing Tools but more apps):

- **Rewrite** is semantically vague. "Rewrite it" can mean change words, change tone, or regenerate from scratch. Users will either pick it when they meant Polish, or pick it and not know what they'll get. Custom subsumes the explicit cases.
- **Expand** has low daily-use frequency in the email/Slack/comment surfaces that are Phase 1's wedge. It fits long-form writing more — a smaller slice.
- **Translate** is high-value but adds a target-language picker — extra design surface, extra implementation node. Defer.
- **Tone shifts** (more formal / more casual) are *missing* from the prototype set and are high-frequency for the "is this email too tense?" / "this slack message sounds too stiff" cases that define the wedge. Apple Writing Tools has them as separate items (Friendly / Professional). Bundling them under Polish loses precision.
- **Proofread vs. Polish** — some users want pure grammar/spelling fixes preserving voice exactly; others want light rephrasing. Apple separates them. Bundling them risks "the AI changed my sentence when I just wanted a comma."

The guiding principle: **one-click actions should each have a precise, predictable behavior.** Rewrite fails that test. Polish and More-formal don't.

## Decision

**Phase 1 ships six menu items:**

1. **Proofread** — fix grammar/spelling/punctuation only. Preserve voice and length exactly.
2. **Polish** — fix grammar + smooth awkward phrasing + minor rephrasing. Preserve meaning, tone, and approximate length.
3. **More formal** — shift tone toward professional. Length may shift slightly.
4. **More casual** — shift tone toward friendly. Length may shift slightly.
5. **Shorter** — preserve meaning, cut words.
6. **Custom** — free-form prompt input.

The menu is presented flat (no sub-menus). Each item runs a fixed system prompt; Custom takes the user's free-form text as the prompt. Translate is deferred to Phase 1.5+ when the conversational surface arrives.

## Alternatives considered

1. **Keep the prototype set unchanged.** Lowest disruption to what was already validated. Rejected: prototype validation was "do these actions feel right when I look at them?", not "did users pick the right action without confusion?" Rewrite/Polish overlap will surface in real usage; better to fix it before shipping.
2. **Minimal (3 + Custom): Polish, Shorter, Custom.** Ships fastest. Rejected: tone shifts are too high-frequency to leave for Custom; the daily-use vocabulary is bigger than 3 items.
3. **Maximal (8 + Custom).** Add tone shifts and Proofread on top of the existing 6. Rejected: menu clutter; overlapping actions (Rewrite still vague) still cause confusion.
4. **Include Translate in Phase 1.** Rejected: adds picker UX (target language, sticky-last-used, auto-detect source) that's a design surface unto itself. Phase 1.5 is the right home for it once the conversational surface is in place to make language selection a chat-affordance rather than a menu-affordance.

## Consequences

- **The PRD's "6 actions" wording becomes literal** — 6 items in the menu — but the contents are different.
- **Phase 1 implementation needs 5 fixed system-prompt templates** (one per non-Custom action) + a Custom-prompt pipeline. The 5 fixed prompts are part of the model-evaluation work — they need to produce predictable, recognizable behavior on the default model.
- **The action set is testable.** Each one-click action has a precise expected behavior, which gives evaluation criteria for Q5 (default model): does Qwen 2.5 7B reliably *proofread* without rephrasing? Does it reliably *shift tone formal* without changing meaning? If not, the model is wrong, not the action set.
- **Future additions have a clear bar:** a new one-click action ships only if its behavior is precise and predictable on the default model. Vague "Rewrite"-style entries don't pass that bar.
- **Translate-deferral commitment:** Phase 1.5 design must include Translate as a first-class addition, not an afterthought.
