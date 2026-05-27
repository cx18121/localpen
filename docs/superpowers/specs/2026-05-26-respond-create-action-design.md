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
Short headers only (no subtitles — the `create` accent pill and the differing result footer carry the behavior difference). Keyboard nav and the sliding focus highlight treat the action rows as **one flat list** top-to-bottom (`menuItems = fixed + [.respond("")] + [.custom("")]`); the headers are visual grouping, not navigation stops.

**Layout change (Codex #7):** the highlight offset is currently `focusedActionIndex * rowHeight`, which assumes a uniform row grid. Headers + the divider break that. Replace the linear offset with a computed `highlightOffset(for: index)` that sums the heights of the rows, headers, and divider physically above the focused row — a small static layout map, since the group structure is fixed. (Row frame measurement via `anchorPreference` is the more robust alternative if the map proves fragile, but the static map is preferred for simplicity.)

### 3. Respond flow
Picking **Respond** enters the existing compose phase (`.customPrompt` / `CustomPromptView`), **but** two state-invariant changes are required first (Codex #2, #10, #11):

- **Thread the action through compose state.** Today `.customPrompt` is entered with `PanelContext(selection:)` and **no action**, and submit unconditionally runs `.custom`. Change both compose entries to carry their action: `pick(.custom)` → `PanelContext(selection:, action: .custom(""))`; `pick(.respond)` → `PanelContext(selection:, action: .respond(""))`. This invariant — *compose always carries its action* — must land before anything downstream pattern-matches it, or the Respond flow silently runs as Custom.
- **Action-aware compose view + submit.** `CustomPromptView` gains an `action` (or compose-mode) parameter so it can set the placeholder (*"How should I reply? (optional)"* for Respond vs *"Custom instruction…"* for Custom) and so submit routes correctly. Replace the direct `onSubmit → submitCustomPrompt` wiring with a single `submitCompose(text)` on the controller that reads `ctx.action` and calls `startGeneration(action: .respond(text))` or `.custom(text)` accordingly.
- **Empty submit allowed for Respond (Codex #3).** `CustomPromptView`'s empty-guard and the controller's submit guard currently reject blank input. For `.respond`, blank is valid (empty = default reply); for `.custom`, blank stays rejected. The guard becomes action-aware.

The captured selection (or typed input — see §3a) is shown above as context. **One-shot** — no back-and-forth (stays inside ADR 0001's quick-action scope).

### 3a. Stimulus source & the no-selection state (Codex #6)
`ActionMenuView` renders in both `.empty` (no capture) and `.captured` phases. Respond operates on the **current working text** — `selectionWithCurrentInput()` — so it works whether the message-to-reply-to was captured *or* pasted into the input field. If that working text is empty (nothing to reply to), the **Respond row is disabled** (dimmed, not focusable/selectable, skipped by arrow-key nav). The five Revise actions keep their existing behavior in `.empty`.

### 4. Prompt + system-prompt routing (Codex #4)
The system prompt is fetched via `ModelRegistry.systemPrompt(for:)`, which delegates to `ActionPrompts` only for `.custom`. Add a `.respond` case there that returns `ActionPrompts.systemPrompt(for: .respond(...))` — Respond's prompt lives in `ActionPrompts`, not per-model `models.toml`, consistent with `.custom`. Without this routing change the generative prompt is never sent.

The `.respond` system prompt: *"Write a new reply to the message the user provides. Output only the reply — no commentary, no quotes, no preamble."* `ActionPrompts.userMessage(for: .respond)` wraps the working text as the message-to-reply-to plus the optional steer.

The prompt assembles in a **`styleContext` placeholder** — a constant currently `""` and the single spot Phase 2's voice injection will fill. No style logic now; just the seam.

### 5. Accept / paste-back semantics
`acceptResult()` branches on `operationClass`, and the branch must be reached by **both** `⌘↩` and bare Return — the non-editing result handler already accepts on bare Return (`PanelController.swift:175`), so making *accept itself* class-aware (rather than gating on the `⌘` modifier) is what guarantees a reply is never pasted back regardless of which key fires (Codex #1):

- **`.revise`** (incl. custom default) — persist `accepted=true`, then paste back over the source selection, as today (may enter `.pasteBackFallback` on failure).
- **`.create`** (respond) — persist the pending interaction with `accepted=true`, **clear `pendingInteraction`**, copy the reply to the clipboard, and dismiss. It must **not** call `textIO.pasteBack` and must **not** be able to enter `.pasteBackFallback` (Codex #8, #9). Note: this is *not* a reuse of `copyResult()` (which only writes the pasteboard and would leave the pending interaction to be flushed as *rejected* on dismiss).

`ResultToolbar` footer labels become class-aware: Create shows `⌘↩ copy reply · esc back`; Revise keeps `⌘↩ accept · ⌘C copy · esc back`.

### 6. Persistence (Codex #5)
No migration. `Interaction.action` stores `"respond"`; `selection` stores the stimulus; `modelOutput`/`accepted`/`editedOutput` work unchanged. The optional **steer reuses the existing `customPrompt` column** — extend `buildInteraction` (which today fills `customPrompt` only for `.custom`) to also store the steer for `.respond`. (For a Create result, `accepted = true` means the reply was copied/taken — see §5.)

## Affected files
- `Models/Action.swift` — `.respond(String)` case (rawValue `"respond"`, label `"Respond"`); `OperationClass { revise, create }` + `operationClass`; `create` action list.
- `Models/ActionPrompts.swift` — `.respond` system + user prompt; `styleContext` placeholder constant.
- `Services/ModelRegistry.swift` — route `.respond` in `systemPrompt(for:)` to `ActionPrompts` (Codex #4).
- `Panel/ActionMenuView.swift` — grouped rendering (REVISE / CREATE headers + divider), `create` accent on Respond row, **non-linear highlight offset** (Codex #7), Respond row disabled when no working text (Codex #6).
- `Panel/PanelController.swift` — `menuItems` includes `.respond`; **compose entries carry their action in `PanelContext`** (Codex #2/#11); `pick(.respond)` → compose; unified `submitCompose(text)` routes by `ctx.action` with action-aware empty-guard (Codex #3/#10); `acceptResult` branches on `operationClass`, with the Create branch persisting `accepted=true` + clearing pending + copy + dismiss, bypassing paste-back (Codex #1/#8/#9); arrow-key nav skips the disabled Respond row.
- `Panel/CustomPromptView.swift` — `action`/mode parameter → adapts placeholder; action-aware empty-guard; submit calls `submitCompose`.
- `Panel/ResultToolbar.swift` + `Panel/PanelView.swift` — class-aware footer labels; compose entry passes the action.
- `Models/PanelState.swift` / `Models/Interaction.swift` — no type changes. New invariant (enforced in `PanelController`): `.customPrompt` is always entered with `ctx.action` set. `buildInteraction` extended to persist the Respond steer in `customPrompt` (Codex #5).
- **New ADR** superseding/amending ADR 0004 (adds Respond + the operation-class concept).
- `DESIGN.md` / `SWIFTUI-SPEC.md` — record the two-class menu + Create semantics.

## Codex review resolutions
Design-review pass (2026-05-26) findings, each now addressed above:
| # | Finding | Resolved in |
|---|---|---|
| 1 | Bare Return already accepts (no ⌘ gate) | §5 — accept itself is class-aware, not modifier-gated |
| 2, 10, 11 | Compose enters with no action → would run as Custom | §3 — action threaded through `PanelContext`; unified `submitCompose` |
| 3 | Empty submit is blocked | §3 — action-aware empty-guard (blank allowed for Respond) |
| 4 | System prompt routes via `ModelRegistry`, not `ActionPrompts` | §4 — add `.respond` case to `ModelRegistry.systemPrompt` |
| 5 | Steer would be lost on persist | §6 — reuse `customPrompt` column |
| 6 | Respond reachable in `.empty` no-selection state | §3a — operates on working text; row disabled when empty |
| 7 | Highlight offset is `index * rowHeight` | §2 — computed non-linear offset map |
| 8 | Copy-then-dismiss records `accepted=false` | §5 — Create branch persists accepted + clears pending first |
| 9 | Create must bypass paste-back + fallback | §5 — Create branch never calls `pasteBack` / `.pasteBackFallback` |

## Out of scope (now)
- Real voice/style matching — Phase 2 (only the `styleContext` seam ships now).
- Multi-turn refinement of a reply — Phase 1.5 conversational scope.
- Additional Create actions (Summarize, Draft) — Respond only.
- Auto-detection of operation class.

## Success criteria
1. Selecting an email in Mail → hotkey → **Respond** → (optional steer) → a coherent reply streams in.
2. Accepting a reply copies it to the clipboard and dismisses — the source email is **not** modified.
3. The five Revise actions behave exactly as before (paste-back unchanged).
4. The menu visibly distinguishes Revise from Create; keyboard nav still flows as one list and the focus highlight lands correctly on every row despite the headers.
5. `styleContext` is a single, obvious injection point for Phase 2 with zero behavior today.
6. With no working text, the Respond row is disabled and arrow-key nav skips it; with text pasted into the input (no capture), Respond still works.
7. A reply is never pasted back over the source — including via bare Return (not just `⌘↩`).
