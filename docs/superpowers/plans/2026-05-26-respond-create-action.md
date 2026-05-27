# Respond (Create action) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generative "Respond" action that drafts a reply to a captured message (a new artifact copied to the clipboard), alongside the existing five transform actions, without crossing into Phase 1.5 conversation or Phase 2 voice.

**Architecture:** Introduce an `OperationClass { revise, create }` on `Action`. `.revise` (the five transforms + Custom default) transforms the selection and pastes back; `.create` (`.respond`) treats the selection as a stimulus and copies a new draft to the clipboard. The action menu groups the two classes under short headers. The compose view (today only Custom) is generalized to carry its action so the same field serves Respond, and `acceptResult` branches on operation class.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, macOS 14. Built with XcodeGen (`project.yml`) → `xcodebuild`. No test target (see plan note below); load-bearing logic is extracted into pure units and verified by build + explicit manual checks.

**Verification note:** This project has no XCTest target (hosted-test injection conflicts with the hardened-runtime, manually-signed, `LSUIElement` app). Each task is gated by a successful `xcodebuild` build plus a specific manual behavioral check. The pure-logic additions (`operationClass`, `steerText`, `fromCompose`, `ActionPrompts`) are written as isolated, side-effect-free units so they are trivially testable if a target is added later.

**Standard build command (used in every task):**
```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
# Expected: ** BUILD SUCCEEDED **
```

---

## File map

| File | Responsibility | Change |
|---|---|---|
| `Localpen/Models/Action.swift` | Action enum + pure helpers | `.respond` case, `OperationClass`, `operationClass`, `steerText`, `fromCompose`, `createActions` |
| `Localpen/Models/ActionPrompts.swift` | Prompt assembly | `.respond` system + user prompt, `styleContext` seam |
| `Localpen/Services/ModelRegistry.swift` | System-prompt routing | route `.respond` to `ActionPrompts` |
| `Localpen/Panel/PanelController.swift` | State + flow | `menuItems`, compose-carries-action, `submitCompose`, class-aware `acceptResult`, nav skip, steer persistence |
| `Localpen/Panel/CustomPromptView.swift` | Compose field | `action` param → placeholder; pass raw text to `onSubmit` |
| `Localpen/Panel/PanelView.swift` | Panel layout | pass action to compose; pass `isCreate` to toolbar |
| `Localpen/Panel/ActionMenuView.swift` | Action menu | grouped headers + divider, create accent, non-linear highlight offset, disabled Respond row |
| `Localpen/Panel/ResultToolbar.swift` | Result footer | class-aware hints |
| `docs/adr/0009-respond-create-action-class.md` | Decision record | new ADR superseding ADR 0004 |
| `DESIGN.md`, `SWIFTUI-SPEC.md` | Contracts | record two-class menu + Create semantics |

---

## Task 1: Action model — `.respond`, operation class, pure helpers

**Files:**
- Modify: `Localpen/Models/Action.swift`

- [ ] **Step 1: Add the `.respond` case and update `rawValue` / `label`**

In `Localpen/Models/Action.swift`, add `case respond(String)` after `case shorter` and before `case custom(String)`:

```swift
    case shorter
    case respond(String)
    case custom(String)
```

Add to `rawValue` (before `.custom`):

```swift
        case .respond:     return "respond"
```

Add to `label` (before `.custom`):

```swift
        case .respond:     return "Respond"
```

- [ ] **Step 2: Add `OperationClass`, `operationClass`, `steerText`, `createActions`, and `fromCompose`**

Append inside the `Action` enum, after the `static let fixed` line:

```swift
    enum OperationClass {
        /// Transforms the selection in place; output pastes back over it.
        case revise
        /// Uses the selection as a stimulus; output is a new artifact copied
        /// to the clipboard, never pasted back over the source.
        case create
    }

    /// Which class this action belongs to. Drives prompt framing AND accept
    /// behavior, so the two can't drift apart. Custom defaults to `.revise`
    /// (paste-back); the user can still copy a custom result instead.
    var operationClass: OperationClass {
        switch self {
        case .respond: return .create
        default:       return .revise
        }
    }

    /// The free-text the user supplied for the actions that carry one
    /// (the Custom instruction, the Respond steer). Persisted in
    /// `Interaction.customPrompt`.
    var steerText: String? {
        switch self {
        case .custom(let t):  return t.isEmpty ? nil : t
        case .respond(let t): return t.isEmpty ? nil : t
        default:              return nil
        }
    }

    /// Actions that produce a new artifact rather than revising the selection.
    static let createActions: [Action] = [.respond("")]

    /// Resolves the compose field's entered text into the action to generate,
    /// or nil when the submission should be ignored. Respond accepts empty
    /// (empty steer = a sensible default reply); Custom requires non-empty.
    static func fromCompose(base: Action, text: String) -> Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch base {
        case .custom:  return trimmed.isEmpty ? nil : .custom(trimmed)
        case .respond: return .respond(trimmed)
        default:       return nil
        }
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: **non-exhaustive switch errors** in `ActionPrompts.systemPrompt`/`userMessage` and `ModelRegistry.systemPrompt` (they switch over `Action` without a catch-all and don't yet handle `.respond`). This is expected. **Tasks 1–3 form one buildable unit** — the clean `** BUILD SUCCEEDED **` returns after Task 3. Do not commit Task 1 alone; commit at the points indicated in Tasks 2 and 3.

- [ ] **Step 4: Manual sanity check (logic)**

Confirm by reading: `Action.respond("").operationClass == .create`; `Action.proofread.operationClass == .revise`; `Action.fromCompose(base: .respond(""), text: "") == .respond("")`; `Action.fromCompose(base: .custom(""), text: "  ") == nil`.

- [ ] **Step 5: Do not commit yet** — the build is red until Task 3. Proceed to Task 2.

---

## Task 2: Generative prompt + style seam

**Files:**
- Modify: `Localpen/Models/ActionPrompts.swift`

- [ ] **Step 1: Add the `styleContext` seam and `.respond` system prompt**

In `Localpen/Models/ActionPrompts.swift`, add a constant at the top of the `enum ActionPrompts` body:

```swift
    /// Phase-2 voice injection point. Empty today: appended to generative
    /// system prompts so a learned style can be slotted in later with no
    /// structural change. Keep the leading space so concatenation reads
    /// cleanly when non-empty.
    static let styleContext: String = ""
```

Add a `.respond` case to `systemPrompt(for:)` (before `case .custom`):

```swift
        case .respond:
            return """
            Write a new reply to the message the user provides. Match a natural, \
            human email/message register. If the user includes an instruction, \
            follow it; otherwise write a concise, appropriate reply. \
            Output only the reply — no commentary, no quotes, no preamble, no subject line.
            """ + styleContext
```

- [ ] **Step 2: Add `.respond` handling to `userMessage(for:)`**

Replace the body of `userMessage(for:)` so `.respond` wraps the stimulus and optional steer. The function currently special-cases `.custom`; add `.respond` alongside it:

```swift
    static func userMessage(for action: Action, text: String) -> String {
        switch action {
        case .custom(let instruction):
            if text.isEmpty { return instruction }
            return "Instruction: \(instruction)\n\nText:\n\(text)"
        case .respond(let steer):
            let base = "Message to reply to:\n\(text)"
            return steer.isEmpty ? base : "\(base)\n\nHow to reply: \(steer)"
        default:
            return text
        }
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: still **non-exhaustive switch error** in `ModelRegistry.systemPrompt` (fixed in Task 3). `ActionPrompts` errors should now be gone.

- [ ] **Step 4: Manual sanity check**

Read to confirm: `systemPrompt(for: .respond(""))` contains "Write a new reply" and ends with `styleContext` (empty now); `userMessage(for: .respond(""), text: "Hi")` == `"Message to reply to:\nHi"`; with steer `"decline"` it appends `"\n\nHow to reply: decline"`.

- [ ] **Step 5: Do not commit yet** — proceed to Task 3, which restores a clean build and commits Tasks 1–3 together.

---

## Task 3: Route the generative system prompt through ModelRegistry

**Files:**
- Modify: `Localpen/Services/ModelRegistry.swift`

- [ ] **Step 1: Add a `.respond` case to `systemPrompt(for:)`**

In `Localpen/Services/ModelRegistry.swift`, `func systemPrompt(for action: Action)`, add a `.respond` case next to the existing `.custom` case so Respond's prompt comes from `ActionPrompts` (not per-model `models.toml`):

```swift
        case .custom:      return ActionPrompts.systemPrompt(for: .custom(""))
        case .respond:     return ActionPrompts.systemPrompt(for: .respond(""))
```

(Place `.respond` adjacent to `.custom`; both bypass the model's TOML prompt table. The associated string is irrelevant to system-prompt selection, so `("")` is fine.)

- [ ] **Step 2: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual sanity check**

Read `systemPrompt(for:)` and confirm `.respond` returns the generative prompt (not a TOML transform prompt) regardless of active model.

- [ ] **Step 4: Commit (Tasks 1–3 together — first clean build)**

```bash
git add Localpen/Models/Action.swift Localpen/Models/ActionPrompts.swift Localpen/Services/ModelRegistry.swift
git commit -m "Respond foundation: .respond action, OperationClass, generative prompt + routing"
```

---

## Task 4: Compose carries its action — generalize the Custom flow to serve Respond

This is the load-bearing invariant (Codex #2/#10/#11): `.customPrompt` must always carry its action, and submission must route by that action.

**Files:**
- Modify: `Localpen/Panel/PanelController.swift`
- Modify: `Localpen/Panel/CustomPromptView.swift`
- Modify: `Localpen/Panel/PanelView.swift`

- [ ] **Step 1: Add `.respond` to the menu list**

In `PanelController.swift`, change `menuItems`:

```swift
    static let menuItems: [Action] = Action.fixed + [.respond("")] + [.custom("")]
```

- [ ] **Step 2: Route both compose actions through `pick`, carrying the action**

Replace `func pick(_ action: Action)`:

```swift
    func pick(_ action: Action) {
        switch action {
        case .custom, .respond:
            // Compose phase always carries its action in the context so submit,
            // the toolbar, accept, and persistence can all read it. Without this
            // the Respond flow silently runs as Custom.
            state = .visible(PanelContext(selection: selectionWithCurrentInput(), action: action), .customPrompt)
        default:
            startGeneration(action: action, selection: selectionWithCurrentInput())
        }
    }
```

- [ ] **Step 3: Replace `submitCustomPrompt` with action-routing `submitCompose`**

Replace `func submitCustomPrompt(_ text: String)`:

```swift
    func submitCompose(_ text: String) {
        guard case .visible(let ctx, .customPrompt) = state, let base = ctx.action else { return }
        guard let action = Action.fromCompose(base: base, text: text) else { return }
        startGeneration(action: action, selection: ctx.selection)
    }
```

- [ ] **Step 4: Update `CustomPromptView` to carry the action and pass raw text**

In `CustomPromptView.swift`, add an `action` property and adapt the placeholder + submit. Replace the struct's stored properties and the placeholder/editor section:

Add property (top of struct, before `@State private var text`):

```swift
    let action: Action
```

Replace the placeholder `Text(...)`:

```swift
                        Text(isRespond ? "How should I reply?  (optional)" : "Type a custom prompt…")
```

Add a computed helper inside the struct:

```swift
    private var isRespond: Bool {
        if case .respond = action { return true }
        return false
    }
```

In the `GrowingTextEditor(... onSubmit:)` closure, stop trimming/guarding in the view — pass the raw text so the controller decides (this is what lets empty Respond submit):

```swift
                        onSubmit: { raw in
                            onSubmit(raw)
                        }
```

- [ ] **Step 5: Wire `PanelView` to pass the action and call `submitCompose`**

In `PanelView.swift`, `.customPrompt` case, replace the `CustomPromptView(...)` call:

```swift
                    CustomPromptView(
                        action: ctx.action ?? .custom(""),
                        onSubmit: { controller.submitCompose($0) }
                    )
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual behavioral check**

Reinstall + launch (`open /Applications/Localpen.app`). In TextEdit, select a short paragraph, summon the panel.
- Confirm a new **Respond** row appears (between Shorter and Custom).
- Pick **Respond** → the compose field shows *"How should I reply?  (optional)"*; press Return with the field empty → a reply streams in (not a transformation of the paragraph).
- Pick **Custom** → field shows *"Type a custom prompt…"*; empty Return does **nothing** (no generation).
Both confirm the compose action is threaded correctly.

- [ ] **Step 8: Commit**

```bash
git add Localpen/Panel/PanelController.swift Localpen/Panel/CustomPromptView.swift Localpen/Panel/PanelView.swift
git commit -m "Compose carries its action; Respond reuses the compose field (empty = default reply)"
```

---

## Task 5: Grouped menu — headers, create accent, non-linear highlight, disabled-when-empty

**Files:**
- Modify: `Localpen/Panel/ActionMenuView.swift`
- Modify: `Localpen/Panel/PanelController.swift` (nav skip + `respondEnabled`)

- [ ] **Step 1: Add `respondEnabled` and skip-aware arrow nav in the controller**

In `PanelController.swift`, add a computed property near `currentSelection()`:

```swift
    /// Respond needs something to reply to. False when there's no working text
    /// (no selection and an empty input field) — the row is then disabled and
    /// arrow-key nav skips it.
    var respondEnabled: Bool {
        selectionWithCurrentInput() != nil
    }

    /// Index of `.respond` in `menuItems` (the row that may be disabled).
    private var respondIndex: Int? {
        Self.menuItems.firstIndex { if case .respond = $0 { return true }; return false }
    }
```

Replace the `kVK_UpArrow` / `kVK_DownArrow` cases inside `handleKeyDown` (the `.empty, .captured` branch) so they skip the disabled Respond row:

```swift
            case kVK_UpArrow:
                focusedActionIndex = nextSelectableIndex(from: focusedActionIndex, step: -1)
                return true
            case kVK_DownArrow:
                focusedActionIndex = nextSelectableIndex(from: focusedActionIndex, step: 1)
                return true
```

Add the helper (near the nav code):

```swift
    /// Advances the focused index by `step`, wrapping, skipping the Respond row
    /// when it's disabled. Falls back to the starting index if nothing else is
    /// selectable (defensive — there are always selectable rows).
    private func nextSelectableIndex(from index: Int, step: Int) -> Int {
        let n = Self.menuItems.count
        var i = index
        for _ in 0..<n {
            i = (i + step + n) % n
            if i == respondIndex && !respondEnabled { continue }
            return i
        }
        return index
    }
```

Also guard `pick(.respond)` against the disabled state (defensive — a click shouldn't reach it, but make it safe). In `pick`, at the top of the `.respond` handling, the existing `selectionWithCurrentInput()` already yields nil when empty; add an early guard:

```swift
    func pick(_ action: Action) {
        if case .respond = action, !respondEnabled { return }
        switch action {
```

- [ ] **Step 2: Restructure `ActionMenuView` into grouped rows with a computed highlight offset**

Replace the entire body of `ActionMenuView` with the grouped layout. The highlight offset is now a lookup that accounts for the two headers and the divider above each row.

```swift
import SwiftUI

/// Grouped action menu: a REVISE group (the five transforms), a CREATE group
/// (Respond), and Custom below a divider. Keyboard nav (in
/// PanelController.handleKeyDown) treats the action ROWS as one flat list;
/// headers/divider are visual only. The sliding highlight's vertical offset is
/// computed per row because headers break the uniform row grid.
struct ActionMenuView: View {
    @Bindable var controller: PanelController

    private let rowHeight: CGFloat = 38
    private let headerHeight: CGFloat = 26
    private let dividerHeight: CGFloat = 13

    // Layout: [REVISE header][rows 0..4][CREATE header][row 5][divider][row 6]
    private var reviseRange: Range<Int> { 0..<Action.fixed.count }            // 0..4
    private var respondIdx: Int { Action.fixed.count }                        // 5
    private var customIdx: Int { Action.fixed.count + 1 }                     // 6

    /// Top offset of the highlight for a given row index, accounting for the
    /// headers and divider physically above it.
    private func highlightOffset(for index: Int) -> CGFloat {
        var y = headerHeight                       // REVISE header
        if index < respondIdx {                    // a revise row
            return y + CGFloat(index) * rowHeight
        }
        y += CGFloat(Action.fixed.count) * rowHeight   // past the revise rows
        y += headerHeight                              // CREATE header
        if index == respondIdx { return y }
        y += rowHeight                                 // past Respond
        y += dividerHeight                             // divider
        return y                                       // Custom row
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Spacing.innerRadius)
                .fill(Tokens.accentTint)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Tokens.accent).frame(width: 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.innerRadius))
                .frame(height: rowHeight)
                .padding(.horizontal, Spacing.s4)
                .offset(y: highlightOffset(for: controller.focusedActionIndex))
                .animation(Motion.focusSlide, value: controller.focusedActionIndex)
                // Hide the highlight if it would sit on the disabled Respond row.
                .opacity(controller.focusedActionIndex == respondIdx && !controller.respondEnabled ? 0 : 1)

            VStack(alignment: .leading, spacing: 0) {
                groupHeader("Revise")
                ForEach(reviseRange, id: \.self) { i in row(i) }
                groupHeader("Create")
                row(respondIdx)
                Hairline().padding(.horizontal, Spacing.s4).padding(.vertical, 6)
                row(customIdx)
            }
        }
        .padding(.vertical, Spacing.s2)
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Tokens.textFaint)
            .frame(height: headerHeight, alignment: .bottomLeading)
            .padding(.horizontal, Spacing.s7)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let action = PanelController.menuItems[i]
        let disabled = (i == respondIdx) && !controller.respondEnabled
        ActionRow(action: action, isFocused: controller.focusedActionIndex == i)
            .frame(height: rowHeight)
            .opacity(disabled ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !disabled else { return }
                controller.focusedActionIndex = i
                controller.pick(action)
            }
            .onHover { hovering in
                if hovering && !disabled && controller.lastInputSource == .mouse {
                    controller.focusedActionIndex = i
                }
            }
    }
}
```

- [ ] **Step 3: Give the Respond row its create accent**

The CREATE accent lives in `ActionRow`. Open `Localpen/Panel/ActionRow.swift`, and where the row renders its label/glyph, tint it for `.create` actions. Add near the top of `ActionRow`'s body computation a check and apply `Tokens.accent`-like green only for create. Concretely, add a computed property and use it for the leading glyph/label color:

```swift
    private var isCreate: Bool { action.operationClass == .create }
```

Apply `.foregroundStyle(isCreate ? Tokens.createAccent : <existing>)` to the row's primary label. (If `ActionRow` has no distinct create color, add `Tokens.createAccent` in `Tokens.swift`: `static let createAccent = Color.dynamic(light: .oklch(0.52, 0.12, 150), dark: .oklch(0.80, 0.13, 145))` and a matching `createAccentTint`. Keep it subtle.)

- [ ] **Step 4: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual behavioral check**

Reinstall + launch. Summon with a selection:
- Menu shows **REVISE** header over the five transforms, **CREATE** header over Respond, a divider, then Custom. Respond has a subtle green accent.
- Arrow-key down through every row: the highlight lands cleanly centered on each row (no drift from the headers). Confirms `highlightOffset`.
Summon with **no** selection and an empty input:
- Respond row is dimmed; arrow-key nav skips over it (never lands on it); clicking it does nothing.
Type/paste text into the input field (no capture): Respond becomes enabled and selectable.

- [ ] **Step 6: Commit**

```bash
git add Localpen/Panel/ActionMenuView.swift Localpen/Panel/PanelController.swift Localpen/Panel/ActionRow.swift Localpen/DesignSystem/Tokens.swift
git commit -m "Grouped Revise/Create menu: headers, create accent, computed highlight offset, disabled Respond"
```

---

## Task 6: Class-aware accept + result footer

**Files:**
- Modify: `Localpen/Panel/PanelController.swift`
- Modify: `Localpen/Panel/ResultToolbar.swift`
- Modify: `Localpen/Panel/PanelView.swift`

- [ ] **Step 1: Make `acceptResult` branch on operation class**

In `PanelController.swift`, replace `func acceptResult()` so a Create result copies + dismisses (persisting accepted, clearing pending) and never paste-backs:

```swift
    func acceptResult() {
        guard case .visible(let ctx, .result(let text, _)) = state,
              let action = ctx.action,
              let session = current else { return }
        let sel = ctx.selection

        // Persist as accepted (reuse the pending interaction if present).
        if var pending = session.pendingInteraction {
            pending.accepted = true
            pending.editedOutput = (text == pending.modelOutput) ? nil : text
            persistInteraction(pending)
        } else {
            persistInteraction(buildInteraction(selection: sel, action: action, output: text, accepted: true, edited: nil))
        }
        session.pendingInteraction = nil

        switch action.operationClass {
        case .create:
            // A new artifact: leave it on the clipboard, never paste back over
            // the source. Bypasses pasteBack and the .pasteBackFallback state.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            state = .hidden
            current = nil
            hidePanelAnimated()
        case .revise:
            let capture = session.capture
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.textIO.pasteBack(result: text, capture: capture)
                guard self.current === session else { return }
                if result == .skipped {
                    self.state = .visible(PanelContext(selection: sel, action: action), .error(.pasteBackFallback))
                } else {
                    self.state = .hidden
                    self.current = nil
                    self.hidePanelAnimated()
                }
            }
        }
    }
```

(Note: because `acceptResult` itself is class-aware, the existing bare-Return accept path in `handleKeyDown` already does the right thing for Create — Codex #1.)

- [ ] **Step 2: Make the result footer class-aware**

In `ResultToolbar.swift`, add an `isCreate` property:

```swift
    var isCreate: Bool = false
```

In the `case .result:` branch, show create-specific hints:

```swift
            case .result:
                if isCreate {
                    KbdHint("⌘↩", "copy reply")
                    KbdHint("esc", "back")
                } else {
                    KbdHint("⌘↩", "accept")
                    if justCopied {
                        Text("copied ✓").font(Typography.pill).foregroundStyle(Tokens.accent)
                    } else {
                        KbdHint("⌘C", "copy")
                    }
                    KbdHint("esc", "back")
                }
```

- [ ] **Step 3: Pass `isCreate` from `PanelView`**

In `PanelView.swift`, the `.result` `ResultToolbar(...)` call, add:

```swift
                        ResultToolbar(
                            action: action,
                            mode: isEditing ? .editing : .result,
                            justCopied: controller.justCopied,
                            isCreate: action.operationClass == .create,
                            onAccept: { controller.acceptResult() },
                            onBack: { controller.backToMenu() }
                        )
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual behavioral check**

Reinstall + launch. In TextEdit, type a fake email, select it, summon → **Respond** → Return → reply streams.
- Footer shows `⌘↩ copy reply · esc back` (no `⌘C`).
- Press `⌘↩` (and separately test bare `↩`): panel dismisses, the **email text is unchanged** in TextEdit, and pasting (`⌘V`) elsewhere yields the **reply**. Confirms Create never pastes back and copies on both keys.
- Run a Revise action (e.g. Polish) on a selection: `⌘↩` still pastes back over the selection as before.

- [ ] **Step 6: Commit**

```bash
git add Localpen/Panel/PanelController.swift Localpen/Panel/ResultToolbar.swift Localpen/Panel/PanelView.swift
git commit -m "Class-aware accept: Create copies the reply (no paste-back); revise unchanged"
```

---

## Task 7: Persist the Respond steer

**Files:**
- Modify: `Localpen/Panel/PanelController.swift`

- [ ] **Step 1: Use `steerText` in `buildInteraction`**

In `buildInteraction`, replace the custom-only `customPrompt` derivation:

```swift
        let customPrompt: String? = action.steerText
```

(Delete the old `var customPrompt: String? = nil` + `if case let .custom(text) = action { customPrompt = text }` lines.)

- [ ] **Step 2: Build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual behavioral check (persistence)**

Reinstall + launch. Respond to a selection with a steer typed in (e.g. "decline politely"), accept it. Then query the DB:

```bash
sqlite3 ~/Library/Application\ Support/Localpen/history.sqlite \
  "SELECT action, custom_prompt, accepted FROM interactions ORDER BY id DESC LIMIT 1;"
```
Expected: `respond|decline politely|1`. Repeat with an empty steer → `respond||1` (NULL/empty custom_prompt, accepted=1).

- [ ] **Step 4: Commit**

```bash
git add Localpen/Panel/PanelController.swift
git commit -m "Persist Respond steer in interactions.custom_prompt"
```

---

## Task 8: ADR superseding ADR 0004

**Files:**
- Create: `docs/adr/0009-respond-create-action-class.md`
- Modify: `docs/adr/0004-v1-action-set.md` (status note)

- [ ] **Step 1: Write the ADR**

Create `docs/adr/0009-respond-create-action-class.md` following the format of the existing ADRs (read `docs/adr/0004-v1-action-set.md` first to match structure). Content must cover:
- **Status:** Accepted; amends ADR 0004.
- **Context:** Phase 1 shipped a transform-only action set; users need to generate replies, not only revise their own text.
- **Decision:** Introduce an `OperationClass { revise, create }`. Add `Respond` as the first `.create` action. The menu groups the two classes; `.create` results copy to the clipboard and never paste back. A `styleContext` seam is reserved for Phase 2 voice. The action set is now: Proofread / Polish / More formal / More casual / Shorter / **Respond** / Custom.
- **Consequences:** Action menu gains group headers (still one flat keyboard list — no submenus, preserving ADR 0004's spirit). Paste-back semantics are now class-dependent. No persistence migration.
- **Alternatives considered:** auto-detecting class from the selection (rejected — intent isn't in the text, and a classifier call taxes latency); fixing only Custom (rejected — leaves "respond" undiscoverable and paste-back wrong); intent-first menu rebuild (deferred — drifts into Phase 1.5 conversational scope).

- [ ] **Step 2: Add a supersession note to ADR 0004**

At the top of `docs/adr/0004-v1-action-set.md`, under its status line, add:

```markdown
> **Amended by [ADR 0009](./0009-respond-create-action-class.md) (2026-05-26):** adds a `Respond` (Create) action and the revise/create operation-class distinction. The six transform-only actions described below remain; Respond is additive.
```

- [ ] **Step 3: Commit**

```bash
git add docs/adr/0009-respond-create-action-class.md docs/adr/0004-v1-action-set.md
git commit -m "ADR 0009: Respond + revise/create operation class (amends ADR 0004)"
```

---

## Task 9: Update DESIGN.md and SWIFTUI-SPEC.md

**Files:**
- Modify: `DESIGN.md`
- Modify: `SWIFTUI-SPEC.md`

- [ ] **Step 1: DESIGN.md — record the two-class menu**

Find the section describing the action surface / menu (search for the action list). Add a short subsection documenting: the Revise/Create grouping with short headers, the subtle create accent on Respond, and that Create results copy to the clipboard (footer reads "copy reply") rather than pasting back. Keep it consistent with the existing token/voice.

- [ ] **Step 2: SWIFTUI-SPEC.md — record the operation-class + flow**

Find the action/state-machine section (search for `Action` and `PanelState`). Document: `Action.OperationClass`, that `.customPrompt` always carries its action, `submitCompose` routing, the class-aware `acceptResult`, and the `styleContext` Phase-2 seam. Note the action set now includes `.respond`.

- [ ] **Step 3: Commit**

```bash
git add DESIGN.md SWIFTUI-SPEC.md
git commit -m "docs: record Respond/Create action class in DESIGN + SWIFTUI-SPEC"
```

---

## Task 10: Cleanup + end-to-end verification

**Files:**
- Delete: `sketches/respond-create-ux-prototype.html`

- [ ] **Step 1: Delete the throwaway prototype**

```bash
git rm sketches/respond-create-ux-prototype.html
```

- [ ] **Step 2: Full clean build**

```bash
xcodebuild -project Localpen.xcodeproj -scheme Localpen -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: End-to-end manual check against the success criteria**

Reinstall + launch. Verify each spec success criterion:
1. Select an email in TextEdit/Mail → hotkey → Respond → (optional steer) → coherent reply streams.
2. Accept → reply on clipboard, source email unchanged.
3. Each of the five Revise actions still pastes back as before.
4. Menu shows the two groups; arrow nav flows top-to-bottom, highlight lands correctly.
5. `styleContext` is empty and unused (grep confirms single reference point).
6. Respond disabled with no working text; works with pasted input.
7. Reply never pastes back, including via bare Return.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Remove Respond UX prototype; Respond action feature complete"
```

---

## Self-review notes (author)

- **Spec coverage:** §1 operation-class → Task 1; §2 menu → Task 5; §3 compose flow → Task 4; §3a no-selection → Task 5 (disabled row) + Task 4 (working-text stimulus); §4 prompt+routing → Tasks 2–3; §5 accept → Task 6; §6 persistence → Task 7; ADR → Task 8; docs → Task 9. All Codex resolutions (#1–#11) map to Tasks 4–7.
- **Type consistency:** `operationClass`, `steerText`, `fromCompose`, `createActions` (Task 1) are used verbatim in Tasks 5–7. `submitCompose` (Task 4) ← `PanelView` (Task 4). `isCreate` (Task 6) ← `PanelView` (Task 6). `respondEnabled` (Task 5) ← `ActionMenuView` (Task 5).
- **Known soft spot:** Task 5 Step 3 assumes `ActionRow`'s internals; the implementer should read `ActionRow.swift` first and apply the create accent where the primary label color is set. The `Tokens.createAccent` addition is conditional on no existing green token.
