# Free-form Ask + Context Intake — Design Spec

**Date:** 2026-05-28
**Sub-project:** B (per [ROADMAP.md](../../../ROADMAP.md))
**Rung:** 1 — read + draft, never send

---

## 1. Purpose

Pivot the notch from a pure selection-transformer to something you can **ask anything**, while preserving the working selection-transformer core. The hotkey behavior becomes honest about what it is at a given moment:

- **Selection present** → quick-action menu (today, unchanged).
- **Selection absent** → opens directly into a free-form `Ask` input.

This is the first half of the assistant pivot. The second half (rich read-only integrations: mail, calendar, files, screen OCR) is sub-project C and is **explicitly out of scope here**.

## 2. What B is not

Naming it directly so it doesn't slowly accrete:

- **No OCR.** Window-title context is the ceiling for "cheap context" in B. OCR belongs in C with the rest of the read-only integrations and their token-budget / permission concerns.
- **No mail / calendar / files reads.** Same reason.
- **No tool-calling.** That's sub-project D and the gate from rung 1 to rung 2.
- **No "send this for me."** Rung 2.
- **No new model, no new hotkey.** Same Qwen 2.5 7B, same ⌃⌥Space.
- **No clipboard scraping.** Last-N clipboard contents are not auto-attached. Too privacy-loaded for an automatic capture and Memory already covers the "stuff I write" surface.
- **No conversation memory across asks.** Each ask is the seed of its own thread; cross-thread retrieval is out of scope and will be addressed (if ever) only after C lands.

## 3. Architecture

### 3.1 `Action.ask(question:withSelection:)`

A new `Action` enum case, parallel to `.custom` and `.respond`, but **two-valued**: it carries both the user's question AND a `withSelection` flag determined at submit time. This is the resolution to the paste-back invariant problem Codex caught in spec review v1 — see §3.5 for why a single-flag enum case is the right shape.

```swift
case ask(question: String, withSelection: Bool)
```

- `rawValue = "ask"` (the flag does **not** participate in `rawValue` — both variants persist as `"ask"`; the flag is reconstructed from the row's `selection` column, see below).
- `label = "Ask"`
- `pillLabel = "Ask"`
- `seedSentence` = the user's question (verbatim; same pattern as `.respond` / `.custom`).
- `operationClass = withSelection ? .revise : .create`. This is the load-bearing change: when the user submitted with a surviving selection chip, ask is a revise-class operation and paste-back works through the existing `session.canPasteBack && convo.operationClass == .revise` predicate, unchanged. When there was no selection, ask is create-class and Accept is Copy-only — also unchanged in the predicate, just routed by the flag.
- `steerText` returns the question text.
- `fromCompose` handles the empty-text guard the same way `.custom` does (empty question → nil → ignored submit). `fromCompose` always preserves the `withSelection` flag of the `base` action.
- `reconstruct(rawValue: "ask", steer:)` — see §3.5 for how the `withSelection` flag is rehydrated on conversation resume (it cannot be stored in `rawValue` without breaking the existing string contract, so it's derived from the persisted row's `selection` column).

`Action.fixed` is unchanged (only the five quick-action transforms — Ask is reached through its own routing, not the menu's fixed list; see §4).

### 3.2 `ContextProbe` service

A tiny `@MainActor` service that captures cheap, non-AX-scraping context at notch-open time:

```swift
@MainActor
final class ContextProbe {
    struct Snapshot {
        let appName: String?       // "Mail", "Xcode", "Safari"
        let windowTitle: String?   // "Re: budget Q3", "Foo.swift", "github.com — Pull Request"
        let selection: String?     // existing TextIO copy result, if any
    }
    func capture() async -> Snapshot
}
```

- `appName` from `NSWorkspace.shared.frontmostApplication?.localizedName`. No permission needed.
- `windowTitle` via `AXUIElement` on the frontmost PID — `kAXFocusedWindowAttribute` → `kAXTitleAttribute`. Localpen already holds Accessibility permission for clipboard-mediated I/O (CGEvent ⌘C / ⌘V), so this is free.
- If AX access fails for any reason, `windowTitle = nil` and the probe still returns a usable snapshot. Never blocks or prompts.
- `selection` is the existing `TextIO.copySelection()` result. Empty string → nil.
- **Latency budgets are split**, because Codex caught a contradiction in v1: `TextIO.captureSelection` has a fixed ~90 ms clipboard-settle delay that cannot honestly fit a 50 ms target.
  - **App + window probe (the new code)**: < 50 ms in the common case. AX call has a hard timeout (~150 ms ceiling) so a hung frontmost app cannot stall the notch open.
  - **Selection capture**: inherits `TextIO.captureSelection`'s existing budget (~90 ms clipboard settle + read). Unchanged by B.
  - The two run in parallel via `async let app = …; async let sel = …`, so wall-clock for the full probe is bounded by the slower path (~90 ms), not the sum.
  - The 50 ms ceiling applies only to code introduced by B; the selection path is governed by TextIO's existing contract.

### 3.3 `AskContext` (chip model)

The user-facing representation of what context will be attached. Lives in `Models/AskContext.swift`:

```swift
struct AskContext: Equatable {
    var appLabel: String?        // "Mail · Re: budget Q3"
    var selection: String?       // full text; chip shows "32 words selected"
    // Derived from ContextProbe.Snapshot; user can clear either field via the UI.
}
```

`AskContext.from(_ snapshot:)` formats the app + window title into a single `appLabel` (`"\(app) · \(window)"`, or just `"\(app)"` when window title is nil). Empty appLabel + empty selection = no chips shown; ask proceeds with zero auto-context.

### 3.4 `AskInput` view

New SwiftUI view at `Localpen/Panel/AskInput.swift`. Composes the existing component vocabulary (no new design system pieces).

Layout, top to bottom:
1. **Chip rail** — horizontal stack of removable pills, one per non-empty `AskContext` field. Hidden when both are empty. Uses the existing `Tokens.chromeTint` / `Tokens.rowHighlight` palette.
2. **Multiline input** — the existing `GrowingTextEditor` with `"Ask anything"` placeholder. Return submits; ⇧Return inserts newline; Esc dismisses.
3. **Footer hint** — minimal one-line meta showing the keybind ("⏎ to ask · ⇧⏎ newline").

Submitting calls `controller.askSubmitted(question:context:)` (see §3.5).

### 3.5 `PanelController` changes

Two surface-level changes plus one new flow.

**a) No-selection routing.** When `presentForHotkey()` runs and `TextIO.copySelection()` returns empty, route to a new `Phase.ask` (with chips pre-populated from `ContextProbe`) instead of the action menu. When a selection is present, route to the menu as today.

**b) "Ask" reachable from the menu.** The action menu gains a single "Ask" row, rendered by `ActionMenuView` as a dedicated row outside the `Action.fixed` loop (because `Action.fixed` stays scoped to the five transforms — adding `.ask("")` to it would entangle ask with the refine / quick-action plumbing that depends on `Action.fixed`'s shape). Placement of the row (above or below the five transforms) is a UI-pass decision and not material to the architecture. Selecting it transitions to `Phase.ask` with the selection chip pre-attached.

**c) New submit flow:**

```swift
@MainActor
func askSubmitted(question: String, context: AskContext) async {
    let withSelection = (context.selection?.isEmpty == false)
    let action = Action.ask(question: question, withSelection: withSelection)
    // Build the system prompt via ActionPrompts.ask(context:)
    // Compose with memory: memory.compose(base: systemPrompt,
    //                                     for: action,
    //                                     seedAction: action)
    // Create a thread via ConversationStore.createThreadForAsk(question:context:)
    //   (new sibling to createThreadWithSeed — see §3.7).
    // Stream the response, persist the interaction (action="ask",
    // customPrompt=question, selection=context.selection ?? nil).
    // Land in Phase.conversation as turn 2.
}
```

The thread's seed turn renders the user's question (via `Action.seedSentence`), exactly like Respond/Custom threads. Follow-up turns reuse the existing refine path with no changes.

**Paste-back invariant (resolving Codex finding HIGH 2):**
The existing accept paths gate paste-back on `session.canPasteBack && convo.operationClass == .revise`. With `Action.ask(withSelection: Bool)`, `operationClass` derives from the flag — so:

- `ask(withSelection: true)` → `.revise` → `↩ Replace` (paste-back works through the existing predicate, no new code path).
- `ask(withSelection: false)` → `.create` → `↩ Copy` (also works through the existing predicate).

This means **no new paste-back predicate is needed**. `pastesBackOnAccept` continues to be computed from `operationClass`, which is now correctly per-instance via the flag. The live accept path and the resumed-conversation accept path stay in sync because both read `operationClass` from the (rehydrated) seed action — see §3.7 for rehydration.

`Action.fixed` is unchanged. A user who clears the selection chip *before* submitting silently lands in `.ask(withSelection: false)` — the chip's only architectural job is to feed that bool at submit time. After submit, the chip's removal can't change paste-back behavior (you can't un-revise a sent ask), which matches the existing semantics for Respond/Custom.

### 3.6 `ActionPrompts.ask`

A new prompt template:

```text
SYSTEM:
You are Localpen, a local on-device assistant. Answer the user's
question directly and concisely. If the response is a draft (email,
message, note), match the user's voice as captured below.

[<voice card from memory, if any>]
[<facts from memory, if any>]

<context>                            ← only rendered if any chip survived
  app: <appLabel>
  selection: <selection text>
</context>

USER:
<question>
```

The `<context>` block is rendered by `ActionPrompts.ask(context:)` and is omitted entirely when both fields are nil. This makes a chip-removed ask byte-identical at the model boundary to a chip-never-existed ask.

### 3.7 `ConversationStore` extension + ask seed shape

Codex caught (MED 1) that `createThreadWithSeed` requires an `originalSelection` and derives the Recent title from `originalSelection.text` — which collapses for the primary no-selection ask route. Resolution:

**Add a sibling factory** on `ConversationStore`:

```swift
@MainActor
func createThreadForAsk(question: String,
                       contextSelection: String?,
                       sourceApp: String?) async throws -> Thread
```

- The thread's persisted `original_selection` is **the user's question** (so resume / mid-thread paths stay uniform with the rest of the codebase, which assumes a non-empty original_selection).
- The thread's **title** is derived from the question (existing title-derivation logic operates on the seed text). If `contextSelection` survived submit, it's still attached to the seed Interaction row's `selection` column — that is the *attribution* signal, not the title source.
- `sourceApp` is the `AskContext.appLabel` at submit (used in existing source-app columns).

**Why a sibling, not a parameter on `createThreadWithSeed`:** the existing call sites pass a `Selection` struct that's tightly coupled to TextIO's capture flow. Threading an "ask vs. transform" flag through that struct's call sites is more surface area than a clearly-named sibling. The two factories share a private implementation under the hood.

**Rehydrating `Action.ask(withSelection:)` on conversation resume:**
Conversation resume reconstructs the seed action via `Action.reconstruct(rawValue:steer:)`. For `.ask`, the `withSelection` flag is derived from the **persisted Interaction row's `selection` column**:

```swift
case "ask":
    return .ask(question: steer ?? "",
                withSelection: !(selection ?? "").isEmpty)
```

This requires `ConversationStore.resumeThread` to pass the seed interaction's `selection` value to `reconstruct`. Today `reconstruct` takes `(rawValue, steer)`; we extend it to `(rawValue, steer, selection)` — the existing five transforms and `.respond` / `.custom` ignore the new parameter, so the change is additive and zero-risk for the working core.

This is the **one boundary change** the ask sub-project introduces in shared code. Without it, an ask thread loaded from disk would always rehydrate with `withSelection: false` and a refine inside a chip-attached ask thread would silently drop paste-back. Codex's HIGH 2 invariant requires this rehydration to be explicit and tested (see §6).

### 3.8 `PanelState.Phase`

Adds one case:

```swift
case ask(AskContext)
```

`renderKey` returns `"ask"` (sibling to existing `"menu"`, `"conversation"`, `"profile"`). The notch's z-priority and dismiss handling fold in trivially.

### 3.9 Memory integration — both attribution paths

Codex (HIGH 1) caught that `MemoryAttribution` has **two parallel implementations** that must move together: the SQL `selectExemplars` and the Swift `collectGenerationSamples`. The v1 spec only addressed the SQL path. Today both already check `thread_id IS NOT NULL` *before* checking action, so threaded ask rows would currently route to `custom_prompt` correctly — but the invariant is implicit and would silently break under a reorder. The spec now requires **explicit ask handling in both paths**, defense in depth:

**`selectExemplars` SQL:**

```sql
-- ask: question lives in custom_prompt; selection is third-party context, never user voice.
WHEN action = 'ask' THEN custom_prompt
```

Placed *before* the generic `thread_id IS NOT NULL` clause so the ask rule is encoded explicitly. The two clauses produce the same result for the threaded-ask common case, but the explicit clause prevents silent contamination if a future refactor changes how threadIDs are assigned.

**`collectGenerationSamples` Swift:**

```swift
} else if action == "ask" {
    if let c = customPrompt, c.count >= 20 {
        out.append(.init(text: c, source: .conversationTurn))
    }
    // selection (third-party context) and model_output (model prose) are NEVER user-voice for ask.
}
```

Inserted in the precedence chain **before** the generic `threadID != nil` branch, mirroring the SQL ordering. Reuses the existing `.conversationTurn` source label — ask is conceptually the user's authored question inside a conversation, no new source kind required.

**Source label rationale:** the question is the user's authored text submitted into a conversation thread. `.conversationTurn` is the closest existing concept and avoids enum churn; a future revision may split it if the voice-card prompt wants to distinguish "follow-up in thread" from "initial ask" framing.

Other invariants:
- `model_output` remains NEVER a voice sample (mirrors respond).
- `selection` on `.ask` rows is third-party context and NEVER a voice sample (this is the new explicit invariant).
- `edited_output` (a hand-edit on the model's reply) is still the highest-signal source and applies to ask the same way it does to respond.

The four load-bearing Codex-caught regression tests from sub-project A continue to hold; we add **two** new attribution tests for `.ask` — one exercising the SQL path, one exercising the Swift path (see §6).

The post-commit hook is unchanged: `ConversationStore.appendExchange` already fires `.interactionPersisted` for every conversational write, including ask threads. The new `createThreadForAsk` must also fire `.interactionPersisted` for the seed-turn write — same contract as `createThreadWithSeed`. The plan will name this as a required behavior of the new factory.

`MemoryService.compose(base:for:seedAction:)` is called with `seedAction: .ask(...)` — both voice card and facts are injected. The voice card costs little when irrelevant ("what's the capital of France?") and pays off when the ask is a draft request ("write a follow-up to this thread").

### 3.10 Conversation thread mid-thread behavior

Ask threads, like Respond threads, use `Conversation.turns.first?.action` to determine memory gating. So a thread seeded by `.ask` stays `.ask`-gated across all follow-ups, regardless of how the user phrases refines. This reuses the seed-action invariant we shipped in Memory and does not require new code.

Crucially: the seed turn's `withSelection` flag is rehydrated on resume per §3.7. Refines inside a chip-attached ask thread keep `operationClass == .revise`, so Accept stays `↩ Replace` across the whole thread. Refines inside a no-chip ask thread keep `operationClass == .create`, so Accept stays `↩ Copy`. Both paths verified by the resume tests in §6.

## 4. Routing decision table

What the hotkey does, in one place:

| State at hotkey | Behavior |
|---|---|
| Selection present | Quick-action menu (today, unchanged). "Ask" is a row in the menu and pre-attaches the selection chip. |
| Selection absent, app+window readable | Open `Phase.ask` with one chip (`<app> · <window>`). |
| Selection absent, AX permission missing or window unreadable | Open `Phase.ask` with zero chips. Still works. |
| Notch already open in another phase | Hotkey closes the notch (today, unchanged). |

The "no-selection → ask directly" routing is the load-bearing UX bet of this sub-project. It is intentionally aggressive: every hotkey press with empty selection is treated as an ask, not as a no-op or a menu with no actions.

## 5. Files

**Create:**
- `Localpen/Models/AskContext.swift`
- `Localpen/Services/ContextProbe.swift`
- `Localpen/Panel/AskInput.swift`
- Tests: `MemoryAskAttributionTests.swift` (covers both SQL and Swift paths), `ContextProbeTests.swift`, `AskRoutingTests.swift`, `AskContextChipTests.swift`, `AskResumeTests.swift` (new — see §6).

**Modify:**
- `Localpen/Models/Action.swift` — add `.ask(question:withSelection:)` everywhere the existing cases appear. `operationClass` derives from the flag (revise iff `withSelection`). Extend `reconstruct` signature to `(rawValue:steer:selection:)` so the flag rehydrates on resume. Keep `Action.fixed` unchanged.
- `Localpen/Models/ActionPrompts.swift` — add `ask(question:context:memoryBlocks:)`.
- `Localpen/Models/PanelState.swift` — add `case ask(AskContext)` to `Phase` and `"ask"` to `renderKey`.
- `Localpen/Panel/PanelController.swift` — no-selection routing in `presentForHotkey`; `askSubmitted(question:context:)`. `pastesBackOnAccept` requires no new code path — it already reads `operationClass`, which is now correct per-instance for ask.
- `Localpen/Panel/PanelView.swift` — route `.ask` to `AskInput`.
- `Localpen/Panel/ActionMenuView.swift` — add the "Ask" row.
- `Localpen/Services/MemoryAttribution.swift` — explicit `WHEN action = 'ask' THEN custom_prompt` clause in SQL **and** explicit `action == "ask"` branch in `collectGenerationSamples` Swift. Both placed before the generic `thread_id` clause.
- `Localpen/Services/ConversationStore.swift` — **add** `createThreadForAsk(question:contextSelection:sourceApp:)`. Must fire `.interactionPersisted` for the seed-turn write (same contract as `createThreadWithSeed`). Must pass the seed Interaction's `selection` value to `Action.reconstruct` on resume so the `withSelection` flag rehydrates correctly.
- `Localpen/AppDelegate.swift` — construct `ContextProbe` and inject into `PanelController`.
- `DESIGN.md` — small addition noting the Ask chip pattern (reuses existing tokens; no new design system pieces).

**Do not touch:**
- `MemoryService.swift` — `.ask` flows through the same `compose` API; no code change needed.
- `Persistence.swift` — schema is unchanged; `action = "ask"` is just a new string value in the existing TEXT column. **No migration.**

## 6. Tests (the ones that must exist)

**Attribution (both paths — Codex HIGH 1 invariant):**
- **`MemoryAskAttributionTests.test_sqlExemplarsPickCustomPromptOnAskRows`** — `selectExemplars` SQL: for an `.ask` row with non-empty selection, `custom_prompt` is returned, `selection` and `model_output` are not. Proves the explicit SQL clause is reached.
- **`MemoryAskAttributionTests.test_swiftSamplesPickCustomPromptOnAskRows`** — `collectGenerationSamples` Swift: for an `.ask` row with non-empty selection, the emitted Sample has `text == customPrompt` and `source == .conversationTurn`; `selection` and `model_output` are never the chosen text. Proves the explicit Swift branch is reached.
- **`MemoryAskAttributionTests.test_editedOutputStillWinsOnAskRows`** — if the user hand-edited the model's reply, that edit (not custom_prompt) is the sample — preserves the existing edited_output precedence across both paths.

**Routing (PanelController):**
- **`AskRoutingTests.test_emptySelectionRoutesToAskPhase`** — `presentForHotkey` with empty TextIO copy lands in `Phase.ask`, not the menu.
- **`AskRoutingTests.test_selectionPresentRoutesToMenu`** — opposite of above; preserves today's behavior.
- **`AskRoutingTests.test_askMenuRowPreAttachesSelectionChip`** — selecting Ask from the menu carries the selection into `AskContext.selection` and submitting produces `Action.ask(withSelection: true)`.

**Paste-back invariant (Codex HIGH 2 — both live and resumed):**
- **`AskContextChipTests.test_chipPresent_producesReviseClassAction`** — submitting an ask with a surviving selection chip yields `Action.ask(withSelection: true)` whose `operationClass == .revise`.
- **`AskContextChipTests.test_chipRemoved_producesCreateClassAction`** — clearing the selection chip before submit yields `Action.ask(withSelection: false)` whose `operationClass == .create`.
- **`AskResumeTests.test_resumedAskThread_rehydratesWithSelectionFlag`** — persist an ask thread with selection, reload via `ConversationStore.resumeThread`, the rehydrated seed `Action.ask` has `withSelection: true` and `operationClass == .revise`. **Load-bearing for HIGH 2** — without correct rehydration, refines inside ask threads silently drop paste-back.
- **`AskResumeTests.test_resumedAskThread_noSelection_isCreateClass`** — same as above for the no-selection case; rehydrated action is create-class, refines stay Copy.

**Prompt shape:**
- **`AskContextChipTests.test_promptOmitsContextBlockWhenAllChipsCleared`** — `ActionPrompts.ask` produces output without any `<context>` block when both `appLabel` and `selection` are nil. The prompt is byte-identical to a chip-never-existed ask.

**ContextProbe:**
- **`ContextProbeTests.test_axFailureFallsBackToAppNameOnly`** — when AX read throws / times out, the snapshot still has `appName` populated and `windowTitle == nil`.
- **`ContextProbeTests.test_emptySelectionReturnsNil`** — empty-string selection normalizes to nil so chip rail is honest.

**Thread shape (Codex MED 1):**
- **`AskResumeTests.test_noSelectionAskShowsInRecentWithQuestionAsTitle`** — a no-selection ask creates a thread whose Recent-list title derives from the user's question, not an empty string. Proves `createThreadForAsk` solved the originalSelection contradiction.

These tests are load-bearing in the same sense as the four memory-arc tests: they encode invariants the rest of the sub-project relies on. Reviewers should not soften them in refactors. The HIGH 2 resume tests in particular guard a silent failure mode — a regression there does not break compilation or surface obviously in manual testing; only the test will catch it.

## 7. Risks & open questions

- **AX timeout behavior on hung apps.** `AXUIElementCopyAttributeValue` can block on an unresponsive frontmost app. We must use the `kAXErrorCannotComplete` timeout path and a hard `Task` cancel deadline (~150ms) so a frozen Mail.app can't freeze the notch. **Implementation must include this guard; the test `test_axFailureFallsBackToAppNameOnly` proves the fallback path but not the timing.** A separate manual smoke test is appropriate.
- **Window-title privacy.** Some apps put genuinely sensitive content in window titles (1Password, Bitwarden, Banking apps). For B we accept this and rely on the chip being **visible and removable**: the user sees the title before sending and can drop it. A future ADR may add a per-app denylist if this becomes a real problem; out of scope here.
- **What "no selection" means in apps that don't expose selection state via clipboard.** Today we test selection by attempting a synthetic ⌘C and checking whether the clipboard changed. In an app where ⌘C is unbound or the clipboard already matched, we may misclassify "selection present" as absent or vice versa. This is a pre-existing TextIO concern; ask routing inherits it but does not amplify it. Mitigation: the menu still has an Ask row, so users with a selection that's mis-detected can still ask.
- **No new model, no new prompt-engineering experiment.** Ask shares Qwen 2.5 7B with every other action. Quality of free-form answers is bounded by the model. If quality is poor we treat that as a model-selection problem (ADR 0005 permits swapping) — not as license to grow B's scope.
- **What if the user types nothing and hits return?** `Action.fromCompose` returns nil for empty `.ask`; the submit is ignored. Visually we should also gray out the implicit "submit" affordance until the input is non-whitespace, but this is a small `AskInput` polish detail, not an architectural concern.

## 8. Out of scope, named explicitly

Restating §2 with the architecture in view, so a future reader sees exactly what was deferred:

- **C — read-only integrations:** Calendar (EventKit), Mail, Files, screen-OCR as context sources. The framework here is `ContextProbe`-shaped but B does not generalize it; C will.
- **D — tool-calling architecture:** Letting the model choose which source to read. B uses a fixed "what I can see right now" probe; D introduces model-driven selection.
- **Rung 2 — act with confirmation:** Any side effect beyond drafting / copying / pasting back over the original selection.

---

## Verification before claiming this is built

The sub-project is done when **all** of:

1. ⌃⌥Space with no selection lands in `AskInput` with chips populated from `ContextProbe`.
2. Submitting an ask creates a conversation thread with the user's question as turn 1 and the streamed response as turn 2; thread shows in Recent with the question as title (no-selection asks must NOT have a blank title).
3. Removing the selection chip before submit flips Accept from `↩ Replace` to `↩ Copy`; the `<context>` block in the prompt omits selection.
4. An ask with a selection chip attached can paste back into the source app via `↩ Replace`.
5. **Resumed ask threads behave identically to live ones.** Reopening a chip-attached ask thread from Recent and submitting a refine still produces `↩ Replace`. (Guards the HIGH 2 invariant; without §3.7 rehydration this silently fails.)
6. `MemoryService` includes voice card + facts in ask prompts (verify by inspecting a composed prompt) and treats `custom_prompt` (the question) as a voice sample for an `.ask` row in **both** the SQL exemplars path and the Swift generation-samples path.
7. All new tests pass; all 53 pre-existing tests still pass.
8. AX permission revoked → notch still opens, ask still works, zero chips shown.
9. The selection-transformer core (Proofread, Polish, More formal, More casual, Shorter, Custom, Respond) is byte-identical in behavior to today. No regression in the working core.
