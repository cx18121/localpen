# Localpen Phase 1 — Build Plan

Phase 1 task breakdown. Plain markdown; no GSD scaffolding. Vertical-slice / tracer-bullet approach — get an end-to-end loop working in one app on day 1, then expand.

Upstream contracts: [DESIGN.md](./DESIGN.md) (what it looks like) · [SWIFTUI-SPEC.md](./SWIFTUI-SPEC.md) (how it's built) · [docs/adr/](./docs/adr/) (immutable decisions).

---

## Phase 1 goal

Ship the slab: a native macOS .dmg that, after install + permission + model-download, lets the user select text in any reasonable app, press `⌃⌥Space`, pick one of six actions, watch the result stream into a floating panel, and accept it with `⌘↩` to paste back into the source app. Both themes. <500ms hotkey-to-first-token on Qwen 2.5 7B Q4_K_M on M2 16GB+.

---

## Approach — vertical slices, not horizontal layers

The build order is **deepening end-to-end loops**, not "build all of layer A, then all of layer B." The first milestone (M1) gets the entire hotkey→capture→model→stream→paste-back loop working in a single app (TextEdit) with one action (Polish), no polish, no settings. Every later milestone adds depth/breadth to that loop without ever leaving it broken.

Rationale: "Interface quality is the gate" (Key Principle 1). You can't tell if the panel feels right until the full loop runs. Building horizontally would leave the feel question unanswered until month 2.

---

## Definition of Phase 1 done

1. Signed + notarized `.dmg` installs cleanly on a fresh M-series Mac.
2. First-run flow completes: AX permission granted, default model downloaded, panel becomes summonable.
3. All 6 actions (Proofread / Polish / More formal / More casual / Shorter / Custom) produce sensible results on test prompts.
4. End-to-end loop works in TextEdit, Mail, Notes, plus at least 3 of: Slack, Cursor, Gmail-in-Chrome, Discord, Notion.
5. Settings reachable via `⌘,` with hotkey recorder + model picker + history controls.
6. Visual design matches [DESIGN.md](./DESIGN.md): Restrained palette, Dark-first, motion specs, microcopy.
7. Every interaction persists to `~/Library/Application Support/Localpen/history.sqlite` (verifiable by `sqlite3` query).
8. Latency target met: <500ms hotkey-to-first-token on Qwen 2.5 7B Q4_K_M on M2 16GB+.

---

## Milestones

### M0 — Project bootstrap

Setup. Nothing user-facing.

- [ ] **M0.1** Create Xcode project. App target. Bundle ID `app.localpen.Localpen` (provisional, follow ADR 0007 final-name decision).
- [ ] **M0.2** Set deployment target to macOS 14.0.
- [ ] **M0.3** Add SPM dependencies: `KeyboardShortcuts`, `GRDB.swift`, `TOMLKit`. (Originally specced as MASShortcut; swapped per [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md).)
- [ ] **M0.4** Set up `.gitignore` (Xcode, Swift, macOS standard).
- [ ] **M0.5** First commit. Push to private GitHub repo. (Public visibility flips at HN launch.)
- [ ] **M0.6** Skeleton file structure per [SWIFTUI-SPEC.md §13](./SWIFTUI-SPEC.md). Empty files OK; structure first.
- [ ] **M0.7** Acquire a Qwen 2.5 7B Instruct Q4_K_M GGUF manually for dev. Stash at `~/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf` (you'll automate this in M4).
- [ ] **M0.8** Build a `llama-server` binary from a pinned llama.cpp tag (e.g. `b4500`). Drop into `Localpen.app/Contents/Resources/llama-server`. Verify it runs from the command line against the GGUF.

**Done when:** project builds, runs as an empty window, llama-server runs standalone serving the dev model.

---

### M1 — Tracer bullet

The smallest end-to-end loop. One app, one action, no menu, no polish.

- [ ] **M1.1** `LocalpenApp` + `AppDelegate` shells. Empty `Window("First Run", id: "first-run")` scene; `MenuBarExtra("Localpen", ...)` with just a Quit item.
- [ ] **M1.2** `FloatingPanel` NSPanel subclass per [SWIFTUI-SPEC.md §4.1](./SWIFTUI-SPEC.md). `PanelController` shows/hides it.
- [ ] **M1.3** `HotkeyService` wraps `KeyboardShortcuts.onKeyDown(for: .toggleLocalpen)`. Default `⌃⌥Space` set via `KeyboardShortcuts.Name.default`. On fire, call `PanelController.toggleFromHotkey()`.
- [ ] **M1.4** `TextIO.captureSelection()` — synthetic ⌘C + pasteboard save + read + return `Selection`. Per [SWIFTUI-SPEC.md §9.1](./SWIFTUI-SPEC.md). Test by hotkey-firing while text is selected in TextEdit; verify the captured string is correct.
- [ ] **M1.5** `LlamaServerController` — spawn `llama-server` subprocess on app launch with the dev model. Poll `/health` until ready.
- [ ] **M1.6** `StreamingClient.complete(prompt: String, action: Action) -> AsyncThrowingStream<String, Error>`. Wrap llama-server's `/completion` SSE endpoint with `URLSession.bytes(for:)`. For M1, hardcode the system prompt for "Polish".
- [ ] **M1.7** Minimal `PanelView`: shows captured selection text + "Polish" button + streaming-result Text. No menu, no styling, no states — just the happy path. Wire button to `StreamingClient.complete` and append tokens to `@State var result`.
- [ ] **M1.8** `TextIO.pasteBack(result:)` — write to pasteboard, re-activate frontmost app, synthetic ⌘V, restore pasteboard. Per [SWIFTUI-SPEC.md §9.2](./SWIFTUI-SPEC.md).
- [ ] **M1.9** Wire `⌘↩` in PanelView to call `pasteBack(result:)`. Dismiss panel after.
- [ ] **M1.10** Time the hotkey→first-token interval. Add `os.signpost` instrumentation. Inspect in Instruments.

**Done when:** in TextEdit, select a sentence, press `⌃⌥Space`, click "Polish", watch tokens stream, press `⌘↩`, original selection is replaced by the polished version. Loop feels coherent. First-token time logged.

This is the moment of truth for the architecture. If the loop feels wrong here, debug before going further.

---

### M2 — Action menu + state machine

Replace M1's bare prototype panel with the real state-machine-driven UI.

- [ ] **M2.1** `PanelState` enum per [SWIFTUI-SPEC.md §6](./SWIFTUI-SPEC.md). All 7 states (`.hidden` / `.empty` / `.captured` / `.customPrompt` / `.generating` / `.result` / `.error`).
- [ ] **M2.2** `Action` enum (`.proofread / .polish / .moreFormal / .moreCasual / .shorter / .custom(String)`).
- [ ] **M2.3** `Selection` struct.
- [ ] **M2.4** Refactor `PanelController` to drive transitions, not direct view state.
- [ ] **M2.5** `PanelView` switches on `PanelState`, renders the appropriate sub-view.
- [ ] **M2.6** `SelectionBlock` sub-view per [DESIGN.md §3.4](./DESIGN.md) — quote rule + italic selection + "from <App>" metadata.
- [ ] **M2.7** `ActionMenuView` — 6 rows. `@FocusState` for keyboard focus. Arrow keys move focus; Return triggers `onPick(Action)`. Default focus = Polish.
- [ ] **M2.8** `ActionRow` sub-view — label + focus indicator (2pt accent left-rail + tinted bg) per [DESIGN.md §3.4](./DESIGN.md).
- [ ] **M2.9** `CustomPromptView` — textarea + footer. Return submits; ⌫ on empty returns to menu.
- [ ] **M2.10** `ResultView` — display mode (Text + StreamingCaret) during `.generating`; transitions to TextEditor for editing on `.result(isEditing: true)`.
- [ ] **M2.11** `ResultToolbar` — action pill (left) + accept hints (right).
- [ ] **M2.12** `PanelFooter` for menu state — hint strip "↑↓ select · ↩ apply · esc dismiss".
- [ ] **M2.13** `StreamingCaret` view with blink animation per [DESIGN.md §2.6](./DESIGN.md).
- [ ] **M2.14** All 6 action system prompts in code (placeholder location — they'll move to models.toml in M3). Verify each produces sensible output on a test prompt.
- [ ] **M2.15** Keyboard contract per [DESIGN.md §5.1](./DESIGN.md): Esc dismisses, ⌫ from result returns to menu, click outside dismisses.

**Done when:** full keyboard navigation works. All 6 actions produce results on the test selection. State machine handles all transitions cleanly.

---

### M3 — Persistence, model registry, anchor store

The infrastructure that lives behind the panel.

- [ ] **M3.1** `Persistence` service — GRDB stack with `DatabaseQueue` opening `history.sqlite`.
- [ ] **M3.2** `DatabaseMigrator` registers the `v1.create_interactions` migration per [SWIFTUI-SPEC.md §11.3](./SWIFTUI-SPEC.md).
- [ ] **M3.3** `Interaction` record (FetchableRecord + PersistableRecord).
- [ ] **M3.4** `PanelController.acceptResult()` builds an `Interaction` and saves it asynchronously.
- [ ] **M3.5** Verify with `sqlite3 history.sqlite "SELECT * FROM interactions ORDER BY id DESC LIMIT 5;"` after a few uses.
- [ ] **M3.6** `models.toml` resource file per [SWIFTUI-SPEC.md §12.2](./SWIFTUI-SPEC.md). Single entry: Qwen 2.5 7B Instruct.
- [ ] **M3.7** `ModelRegistry` — load TOML at boot via TOMLKit, expose `activeModel`.
- [ ] **M3.8** Move M2's hardcoded system prompts into models.toml; load them via ModelRegistry.
- [ ] **M3.9** `HardwareFingerprint` — chip family, memory, disk-free probe. Write once to `hardware.json` on first launch.
- [ ] **M3.10** `AnchorStore` — UserDefaults-backed per-bundle-ID panel anchor per [SWIFTUI-SPEC.md §4.3](./SWIFTUI-SPEC.md).
- [ ] **M3.11** Wire `PanelController` to consult AnchorStore on show; observe NSPanel `windowDidMove` to write back.
- [ ] **M3.12** Unit tests: TextIO clipboard round-trip, Persistence migration + write/read, ModelRegistry TOML parsing.

**Done when:** every interaction lands in SQLite. Panel remembers its position per source app. Models load from config, not from code.

---

### M4 — First-run flow + Settings

The flows the user hits before steady state.

- [ ] **M4.1** AX permission check on launch via `AXIsProcessTrustedWithOptions`. If not granted, route to `FirstRunView(.permission)`.
- [ ] **M4.2** `FirstRunView` per [DESIGN.md S1](./DESIGN.md): headline, body, "Open System Settings" button, "Why?" expandable disclosure.
- [ ] **M4.3** Re-check AX permission on app activation (user returns from System Settings). If granted, transition to model-download check.
- [ ] **M4.4** Check for presence of `~/Library/Application Support/Localpen/models/<active-id>.gguf`. If missing, route to `FirstRunView(.download)`.
- [ ] **M4.5** `ModelDownloadView` per [DESIGN.md S2](./DESIGN.md): headline, subhead, progress bar, bytes-of-total + ETA, history disclosure line, "Use a different model" link, Cancel.
- [ ] **M4.6** `URLSession.downloadTask` with progress reporting. Save to a `.partial` filename; rename atomically on completion. Resumable across app quit.
- [ ] **M4.7** On download complete, dismiss the FirstRunView and surface a brief "Localpen is ready — press `⌃⌥Space` to start" toast or just dismiss silently per DESIGN.md ("no success modal").
- [ ] **M4.8** `Settings` SwiftUI scene with TabView: General / Model / History.
- [ ] **M4.9** General tab: `HotkeyRecorderView` hosts `KeyboardShortcuts.Recorder("Toggle Localpen:", name: .toggleLocalpen)`. Library handles persistence + conflict UI.
- [ ] **M4.10** Model tab: list models from `ModelRegistry`, mark installed vs. not, allow selection. Triggering a non-installed model launches the same download UI as first-run.
- [ ] **M4.11** History tab: row count, "Clear history" button (with confirm dialog), "Export history (JSON)" using `fileExporter`.
- [ ] **M4.12** `MenuBarExtra` `StatusMenu`: "Open Panel" · "Settings…" · "About Localpen" · "Quit".

**Done when:** clean install boots through permission → download → usable state. Settings work. MenuBarExtra is a credible affordance.

---

### M5 — Visual polish (DesignSystem)

Apply the DESIGN.md tokens. This is "Interface quality is the gate" earning its keep.

- [ ] **M5.1** `DesignSystem/Tokens.swift` — Color extensions for every OKLCH token in [DESIGN.md §2.1 + §2.2](./DESIGN.md), both themes. Use `Color(.sRGB, red:, green:, blue:)` — convert OKLCH to sRGB ahead of time, or pull in a tiny oklch→rgb helper.
- [ ] **M5.2** `DesignSystem/Typography.swift` — typed scale per [DESIGN.md §2.3](./DESIGN.md). Font helpers returning configured `Font` instances.
- [ ] **M5.3** `DesignSystem/Spacing.swift` — the `--space-1` through `--space-8` constants per [DESIGN.md §2.4](./DESIGN.md).
- [ ] **M5.4** `DesignSystem/Motion.swift` — `Animation` static helpers for the curves in [DESIGN.md §2.6](./DESIGN.md) (ease-out-quart at 180/120/200/100ms variants).
- [ ] **M5.5** Apply tokens throughout `Panel/*` views. Replace any literal `.gray`, `.red`, hardcoded sizes.
- [ ] **M5.6** Panel appear/dismiss animation (180ms fade + 8pt slide). Tied to `PanelController.showAnimated()` / `hideAnimated()`.
- [ ] **M5.7** Action focus cross-fade animation (100ms linear).
- [ ] **M5.8** Action menu → result region transition (200ms ease-out, opacity-only).
- [ ] **M5.9** Result-accept flash (100ms color flash) before dismiss.
- [ ] **M5.10** Light theme — verify token map at [DESIGN.md §2.2](./DESIGN.md). Test contrast ratios; rebalance any that fall below 4.5:1 against the panel bg.
- [ ] **M5.11** Visual QA pass — open the app, walk through every state, screenshot, compare against the production DESIGN.md mental model and the `sketches/index.html` rendered targets.

**Done when:** the panel matches the design at sketch fidelity. Both themes look intentional. Motion is calm.

---

### M6 — Error handling + edge cases

The unhappy paths.

- [ ] **M6.1** `PanelError` enum per [SWIFTUI-SPEC.md §6](./SWIFTUI-SPEC.md). One case per [DESIGN.md S7](./DESIGN.md).
- [ ] **M6.2** `ErrorBanner` view — single-line message + action button. Used by both the panel region and the first-run window.
- [ ] **M6.3** llama-server crash detection: on streaming connection failure, transition to `.error(.serverDown)`. Retry action re-spawns the server.
- [ ] **M6.4** Hotkey conflict surfacing — rely on `KeyboardShortcuts.Recorder`'s built-in conflict UI in Settings; if registration silently fails, show `.error(.hotkeyConflict)` with link to Settings.
- [ ] **M6.5** Disk-full check before model download. Use `FileManager.attributesOfFileSystem`.
- [ ] **M6.6** Empty-state handling (S3): when `TextIO.captureSelection()` returns nil, transition to `.empty` instead of `.captured`.
- [ ] **M6.7** Generation timeout (>30s without a token): cancel stream, transition to `.error(.timeout)` with Cancel/Wait.
- [ ] **M6.8** Paste-back deny-list: `Resources/known-bad-paste-apps.toml` (bundle IDs). If source app's bundle ID matches, skip synthetic ⌘V and show `.error(.pasteBackFallback)` with "Result copied — press ⌘V in your app."
- [ ] **M6.9** Pasteboard restoration robustness — if app crashes mid-flow, the user's clipboard is recoverable from previous content (or accept "lost intermediate state" as the failure mode).

**Done when:** every error path in DESIGN.md S7 has a tested code path. App doesn't crash on disk-full, server-down, or hotkey-conflict.

---

### M7 — App coverage validation

Manual smoke testing in real apps.

- [ ] **M7.1** Test matrix: for each app, verify capture works (select text → hotkey → see selection in panel) and paste-back works (accept → text appears in app):
  - [ ] TextEdit (baseline, must work)
  - [ ] Apple Mail
  - [ ] Apple Notes
  - [ ] Slack (Electron)
  - [ ] Cursor (Electron)
  - [ ] Discord (Electron)
  - [ ] Gmail in Chrome
  - [ ] Notion (Electron)
- [ ] **M7.2** Document failures: for each app where paste-back fails silently, add its bundle ID to `known-bad-paste-apps.toml`.
- [ ] **M7.3** Test latency on the actual hardware: stopwatch the hotkey-to-first-token time on the dev Mac. Verify <500ms target. Profile in Instruments if not.

**Done when:** at least 6 of the 8 target apps work end-to-end. Failures are documented in the deny-list, not as bugs.

---

### M8 — Distribution

Get a `.dmg` shippable.

- [ ] **M8.1** Apple Developer Program enrollment ($99/yr) if not done. Generate "Developer ID Application" certificate.
- [ ] **M8.2** Code signing configured in Xcode build settings. Verify a Release build signs cleanly.
- [ ] **M8.3** Entitlements: NO sandbox (sandbox + AX + subprocess + global hotkey don't play nicely). Hardened Runtime ON. Required entitlements as identified during signing.
- [ ] **M8.4** `create-dmg` or equivalent script to package the build into a `.dmg` with a window background + drag-to-Applications icon.
- [ ] **M8.5** `notarytool` script to submit the .dmg for notarization. Wait for approval. Staple ticket.
- [ ] **M8.6** Smoke-test installation on a fresh Mac (or a fresh VM / second user account): does Gatekeeper accept it without warnings?
- [ ] **M8.7** Sparkle integration: SPM package, appcast.xml, signed EdDSA key. Or **defer** to M9 if first beta is OK with manual reinstall.
- [ ] **M8.8** GitHub Releases workflow: upload `.dmg`, write release notes, link from README.

**Done when:** a fresh user can download a .dmg from GitHub, install, grant permission, download the model, and use the product.

---

### M9 — Beta + iterate (open-ended)

Not a milestone with deliverables. The post-build polish phase.

- [ ] **M9.1** Recruit 5-10 beta users from r/LocalLLaMA, HN, your network.
- [ ] **M9.2** Set up a private Discord or GitHub Discussions for beta feedback.
- [ ] **M9.3** Track issues; prioritize crashes > AX-coverage gaps > latency > polish.
- [ ] **M9.4** Lock final name decision (per [ADR 0007](./docs/adr/0007-defer-final-name-keep-localpen-as-working-name.md)). USPTO TESS search. Acquire domain. Find-and-replace if renaming.
- [ ] **M9.5** Prepare HN launch: README, demo video, the "Show HN: Localpen — local-only writing companion for macOS" post.
- [ ] **M9.6** Cut Phase 1 final release.

**Done when:** Phase 1 is in users' hands and the next phase (1.5 conversational) can begin.

---

## Dependencies & sequencing

```
M0 → M1
       ↓
       M2 ─┬─→ M5 (polish needs the views to exist)
M1 ────────┤
       M3 ─┘
       ↓
       M4
       ↓
       M6 (needs M2/M3/M4's surfaces to error on)
       ↓
       M7
       ↓
       M8
       ↓
       M9
```

M2, M3, M4 can interleave after M1 lands. M5 is parallel-blockable but won't be productive until M2 views are in place.

---

## Test data — system prompt validation

Develop during M2/M3. Goal: each of the 6 actions produces a predictable, recognizable behavior on the same input selection.

Reference test selection: `"hey can u send me the doc when you get a sec"` (from the sketch prototype — Slack-style casual ask).

Expected behaviors:

| Action | Expected output flavor |
|---|---|
| Proofread | `"Hey, can you send me the doc when you get a sec?"` — only capitalize, fix punctuation, expand "u" |
| Polish | `"Hey — could you send me the doc when you have a sec?"` — light tone preservation, minor cleanup |
| More formal | `"Could you please send me the document when you have a moment?"` — significant tone shift |
| More casual | (close to input; minor lift to fluency) |
| Shorter | `"Send me the doc when you can?"` — meaning preserved, fewer words |
| Custom (e.g., "make it German") | translation result |

Build a small `prompt-eval/` directory of test prompts + expected behaviors. Run by hand during M2/M3 against the actual model. If Qwen 2.5 7B fails any of these reliably, revisit the system prompts in `models.toml` before declaring M3 done.

---

## Out of scope for Phase 1

Named explicitly so we don't drift:

- Conversational surface (Phase 1.5)
- Memory inference / voice learning (Phase 2)
- Personalities / personas (Phase 3)
- Agent / tool calling / MCP (Phase 4)
- Voice input / cross-platform (Phase 5)
- Translate as a one-click action (deferred to Phase 1.5 per [ADR 0004](./docs/adr/0004-v1-action-set.md))
- Auto-pick model based on hardware (Phase 2)
- AX tree-walking / direct text-field writes (see [ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md))
- Vibrancy material on the panel (revisit Phase 2)
- Per-action keyboard shortcuts (`⌘P`, `⌘L`, etc.) in the action menu
- Filter input on the action menu
- Crash reporting / telemetry
- Localization (English-only Phase 1)
- App Store distribution (sandbox precludes it)
- Sparkle delta updates (basic Sparkle in M8; deltas later)
- iCloud / cross-device sync (forever — local-first)

---

## Open questions to resolve during build

Not blockers; decide at the relevant milestone.

1. **OKLCH→sRGB conversion in M5:** write a small helper, or bundle a tiny color library, or precompute the values at design-tool stage. Probably write the helper — under 30 lines.
2. **Sparkle in M8 or M9:** if M8 is straightforward, include Sparkle; otherwise defer to M9 once a real first version exists.
3. **MenuBarExtra style — `.menu` or `.window`:** start with `.menu` (cheap). If the user wants the menu bar to host a mini status dashboard, switch to `.window` in a later phase.
4. **Sandbox decision:** revisit at M8.3 — likelihood is NO sandbox (subprocess + AX + hotkey), but verify entitlements requirements during code signing.
5. **Final name:** unblocks at M9.4. Until then, "Localpen" everywhere.

---

## Working rhythm

- Each task should be a single sitting (~30 min to 4 hr). If a task takes longer, split it.
- Atomic commits per task. Commit messages reference the task (e.g., `M1.4: TextIO.captureSelection() with pasteboard save/restore`).
- After each milestone, do a manual smoke test against the milestone's Done condition. Don't move to the next milestone if any Done bullet fails.
- After M7, time-box additional bug-hunting — Phase 1 ships at "works in 6/8 target apps + happy path solid", not at "zero known bugs."

---

## Pointers

- Design: [DESIGN.md](./DESIGN.md)
- Engineering: [SWIFTUI-SPEC.md](./SWIFTUI-SPEC.md)
- Locked decisions: [docs/adr/](./docs/adr/)
- Glossary: [CONTEXT.md](./CONTEXT.md)
- Product context (for impeccable / future design passes): [PRODUCT.md](./PRODUCT.md)
- Working rules: [CLAUDE.md](./CLAUDE.md)
