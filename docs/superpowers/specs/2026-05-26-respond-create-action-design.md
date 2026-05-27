# Design — "Respond to this": a generative Create action

**Date:** 2026-05-26
**Status:** Approved design, pre-plan
**Touches locked decisions:** amends [ADR 0004](../../adr/0004-v1-action-set.md) (v1 action set); leaves a placeholder seam toward Phase 2 voice.

## Problem

Localpen today can only **revise the user's own selected text** (Proofread / Polish / More formal / More casual / Shorter / Custom). There is no clean way to hand it someone else's text — an email, a message — and say *"draft a reply to this."* The Custom action can technically be coaxed into it (`userMessage` already wraps `Instruction:` + `Text:`), but its system prompt explicitly says *"output only the **transformed** text,"* which fights generative requests and produces unreliable replies.

## Core insight: two operation classes

There are two operation *classes* in the panel, and only one is modeled today:

- **Revise** — the selection *is* the subject; output **replaces** it (paste-back over the source). All five fixed actions.
- **Create** — the selection is *context/stimulus*; output is a **new artifact** that must **not** overwrite the source. "Respond" is the first Create action (Summarize / Draft may follow later).

The two classes differ in three concrete places: **system-prompt framing** (transform vs. generate), **accept/paste-back semantics** (replace-selection vs. copy-to-clipboard — you'd never want a reply to clobber the email you're replying to), and an optional **steer** ("decline politely" vs. just "reply").

**No auto-detection.** Revise-vs-Create can't be inferred from the selection — the intent lives in the user's head, not the text — and a pre-classification model call would tax the <500ms latency budget on every invocation. The action the user picks *is* the intent signal: instant and reliable. The one ambiguous path (Custom, where intent is typed freely) is resolved by the user at accept-time via the dual `⌘↩ accept` / `⌘C copy` affordances already shipped.

## Design (Variant A — grouped menu, validated via HTML prototype)

### 1. Operation-class model
Add `Action.OperationClass { case revise, create }` and a computed `operationClass`. `.respond` → `.create`; everything else (incl. `.custom`) → `.revise` (custom defaults to paste-back, with copy available). This single distinction drives both prompt framing and default accept behavior, so the two classes cannot drift apart.

Add a new case `Action.respond(String)` carrying the optional steer (empty = default reply), mirroring `.custom(String)`. `rawValue = "respond"`, `label = "Respond"`.

### 2. Menu (grouped, short headers)
The action menu renders two labeled groups plus Custom:
```
REVISE
  Proofread / Polish / More formal / More casual / Shorter
CREATE
  Respond            ← subtle green "create" accent
──────────
  Custom…
```
Short headers only (no subtitles — the `create` accent pill and the differing result footer carry the behavior difference). Keyboard nav and the sliding focus highlight treat the whole thing as **one flat list** top-to-bottom (`menuItems = fixed + [.respond("")] + [.custom("")]`); the headers are visual grouping, not navigation stops.

### 3. Respond flow
Picking **Respond** drops into the existing compose view (the `.customPrompt` phase / `CustomPromptView` path), with `ctx.action = .respond("")`, the captured selection shown above as context, and the field re-labeled *"How should I reply? (optional)."* Empty + Return → a sensible default reply; typed steer → guided reply. **One-shot** — no back-and-forth (stays inside ADR 0001's quick-action scope).

### 4. Prompt + style seam
A new generative system prompt for `.respond` lives in `ActionPrompts` (not per-model `models.toml`, consistent with how `.custom` is handled): *"Write a new reply to the message the user provides. Output only the reply — no commentary, no quotes, no preamble."* `userMessage(for: .respond)` wraps the selection as the message-to-reply-to plus the optional steer.

The prompt assembles in a **`styleContext` placeholder** — a constant currently `""` and the single spot Phase 2's voice injection will fill. No style logic now; just the seam.

### 5. Accept / paste-back semantics
`acceptResult()` branches on `operationClass`:
- **`.revise`** (incl. custom default) — paste back over the source selection, as today.
- **`.create`** (respond) — **copy to clipboard + dismiss**; never paste back over the source.

`ResultToolbar` footer labels become class-aware: Create shows `⌘↩ copy reply · esc back`; Revise keeps `⌘↩ accept · ⌘C copy · esc back`. Builds on the dual-affordance polish already shipped.

### 6. Persistence
No migration. `Interaction.action` stores `"respond"`; `selection` stores the stimulus; `modelOutput`/`accepted`/`editedOutput` work unchanged. (For a Create result, `accepted = true` means the reply was copied/taken.)

## Affected files
- `Models/Action.swift` — `.respond(String)` case; `OperationClass` + `operationClass`; `create` action list.
- `Models/ActionPrompts.swift` — `.respond` system + user prompt; `styleContext` placeholder constant.
- `Panel/ActionMenuView.swift` — grouped rendering (REVISE / CREATE headers), `create` accent on Respond row.
- `Panel/PanelController.swift` — `menuItems` includes `.respond`; `pick(.respond)` → compose; submit builds `.respond`; `acceptResult` branches on `operationClass`.
- `Panel/CustomPromptView.swift` — adapt label/placeholder when `ctx.action` is `.respond`.
- `Panel/ResultToolbar.swift` + `Panel/PanelView.swift` — class-aware footer labels.
- **New ADR** superseding/amending ADR 0004 (adds Respond + the operation-class concept).
- `DESIGN.md` / `SWIFTUI-SPEC.md` — record the two-class menu + Create semantics.

## Out of scope (now)
- Real voice/style matching — Phase 2 (only the `styleContext` seam ships now).
- Multi-turn refinement of a reply — Phase 1.5 conversational scope.
- Additional Create actions (Summarize, Draft) — Respond only.
- Auto-detection of operation class.

## Success criteria
1. Selecting an email in Mail → hotkey → **Respond** → (optional steer) → a coherent reply streams in.
2. Accepting a reply copies it to the clipboard and dismisses — the source email is **not** modified.
3. The five Revise actions behave exactly as before (paste-back unchanged).
4. The menu visibly distinguishes Revise from Create; keyboard nav still flows as one list.
5. `styleContext` is a single, obvious injection point for Phase 2 with zero behavior today.
