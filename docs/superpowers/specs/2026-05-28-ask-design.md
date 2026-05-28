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

### 3.1 `Action.ask(String)`

A new `Action` enum case, parallel to `.custom` and `.respond`. Carries the user's question as its associated value.

```swift
case ask(String)
```

- `rawValue = "ask"`
- `label = "Ask"`
- `pillLabel = "Ask"`
- `seedSentence` = the user's question (verbatim; same pattern as `.respond` / `.custom`)
- `operationClass = .create` (new artifact; mirrors `.respond`). Paste-back is still possible when a selection chip was attached at submit, but it's not the default class behavior.
- `steerText` returns the question text.
- `fromCompose` handles the empty-text guard the same way `.custom` does (empty question → nil → ignored submit).
- `reconstruct(rawValue: "ask", steer:)` returns `.ask(steer ?? "")`.

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
- The probe must complete in < 50 ms in the common case; the AX call has a hard timeout so a hung app cannot stall the notch open.

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
    let action = Action.ask(question)
    // Build the system prompt via ActionPrompts.ask(context:)
    // Compose with memory: memory.compose(base: systemPrompt,
    //                                     for: action,
    //                                     seedAction: action)
    // Create a thread via ConversationStore.createThreadWithSeed,
    // stream the response, persist the interaction (action="ask",
    // customPrompt=question, selection=context.selection ?? nil).
    // Land in Phase.conversation as turn 2.
}
```

The thread's seed turn renders the user's question (via `Action.seedSentence`), exactly like Respond/Custom threads. Follow-up turns reuse the existing refine path with no changes.

`pastesBackOnAccept` for an ask thread is `true` iff `context.selection != nil` at submit time. This is consistent with the rule we shipped for the conversation surface and means a chip-removed ask becomes Copy-only — honest about what Accept does.

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

### 3.7 `PanelState.Phase`

Adds one case:

```swift
case ask(AskContext)
```

`renderKey` returns `"ask"` (sibling to existing `"menu"`, `"conversation"`, `"profile"`). The notch's z-priority and dismiss handling fold in trivially.

### 3.8 Memory integration

One additional SQL CASE in `MemoryAttribution.swift`:

```sql
WHEN action = 'ask' THEN custom_prompt
```

Rationale — same as `respond`:
- `custom_prompt` holds the user's question, which is their authored prose. Eligible as a voice sample (subject to existing length/eligibility filters).
- `selection` is third-party context. NOT a voice sample.
- `model_output` is the model's prose. NOT a voice sample.

This is a one-line addition. The four load-bearing Codex-caught regression tests from sub-project A continue to hold; we add one more attribution test for `.ask` (see §6).

The post-commit hook is unchanged: `ConversationStore.appendExchange` already fires `.interactionPersisted` for every conversational write, including ask threads.

`MemoryService.compose(base:for:seedAction:)` is called with `seedAction: .ask` — both voice card and facts are injected. The voice card costs little when irrelevant ("what's the capital of France?") and pays off when the ask is a draft request ("write a follow-up to this thread").

### 3.9 Conversation thread mid-thread behavior

Ask threads, like Respond threads, use `Conversation.turns.first?.action` to determine memory gating. So a thread seeded by `.ask` stays `.ask`-gated across all follow-ups, regardless of how the user phrases refines. This reuses the seed-action invariant we shipped in Memory and does not require new code.

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
- Tests: `MemoryAskAttributionTests.swift`, `ContextProbeTests.swift`, `AskRoutingTests.swift`, `AskContextChipTests.swift`

**Modify:**
- `Localpen/Models/Action.swift` — add `.ask(String)` everywhere the existing cases appear (rawValue, reconstruct, label, pillLabel, seedSentence, operationClass, steerText, fromCompose). Keep `Action.fixed` unchanged.
- `Localpen/Models/ActionPrompts.swift` — add `ask(context:memoryBlocks:)`.
- `Localpen/Models/PanelState.swift` — add `case ask(AskContext)` to `Phase` and `"ask"` to `renderKey`.
- `Localpen/Panel/PanelController.swift` — no-selection routing in `presentForHotkey`; `askSubmitted(question:context:)`; `pastesBackOnAccept` extension for ask threads.
- `Localpen/Panel/PanelView.swift` — route `.ask` to `AskInput`.
- `Localpen/Panel/ActionMenuView.swift` — add the "Ask" row.
- `Localpen/Services/MemoryAttribution.swift` — `WHEN action = 'ask' THEN custom_prompt` CASE.
- `Localpen/AppDelegate.swift` — construct `ContextProbe` and inject into `PanelController`.
- `DESIGN.md` — small addition noting the Ask chip pattern (reuses existing tokens; no new design system pieces).

**Do not touch:**
- `MemoryService.swift` — `.ask` flows through the same `compose` API; no code change needed.
- `ConversationStore.swift` — ask threads use `createThreadWithSeed` / `appendExchange` as-is.
- `Persistence.swift` — schema is unchanged; `action = "ask"` is just a new string value in the existing TEXT column. **No migration.**

## 6. Tests (the ones that must exist)

- **`MemoryAskAttributionTests.test_askPicksOnlyUserAuthoredFields`** — for an `.ask` interaction: `custom_prompt` is the only field eligible as a voice sample; `selection` and `model_output` are excluded. Mirrors the load-bearing respond test.
- **`AskRoutingTests.test_emptySelectionRoutesToAskPhase`** — `presentForHotkey` with empty TextIO copy lands in `Phase.ask`, not the menu.
- **`AskRoutingTests.test_selectionPresentRoutesToMenu`** — opposite of above; preserves today's behavior.
- **`AskRoutingTests.test_askMenuRowPreAttachesSelectionChip`** — selecting Ask from the menu carries the selection into `AskContext.selection`.
- **`AskContextChipTests.test_removingSelectionChipFlipsPasteBackToCopy`** — `pastesBackOnAccept` is true initially, false after the user clears the selection chip.
- **`AskContextChipTests.test_promptOmitsContextBlockWhenAllChipsCleared`** — `ActionPrompts.ask` produces output without any `<context>` block when both fields are nil.
- **`ContextProbeTests.test_axFailureFallsBackToAppNameOnly`** — when AX read throws / times out, the snapshot still has `appName` populated and `windowTitle == nil`.
- **`ContextProbeTests.test_emptySelectionReturnsNil`** — empty-string selection normalizes to nil so chip rail is honest.

These tests are load-bearing in the same sense as the four memory-arc tests: they encode invariants the rest of the sub-project relies on. Reviewers should not soften them in refactors.

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
2. Submitting an ask creates a conversation thread with the user's question as turn 1 and the streamed response as turn 2; thread shows in Recent.
3. Removing the selection chip before submit flips `pastesBackOnAccept` from Replace to Copy; the `<context>` block in the prompt omits selection.
4. An ask with a selection chip attached can paste back into the source app via `↩ Replace`.
5. `MemoryService` includes voice card + facts in ask prompts (verify by inspecting a composed prompt) and treats `custom_prompt` (the question) as a voice sample for an `.ask` row.
6. All eight new tests pass; all 53 pre-existing tests still pass.
7. AX permission revoked → notch still opens, ask still works, zero chips shown.
8. The selection-transformer core (Proofread, Polish, More formal, More casual, Shorter, Custom, Respond) is byte-identical in behavior to today. No regression in the working core.
