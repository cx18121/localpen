# Localpen Phase 1 — SwiftUI / AppKit Implementation Spec

Engineering source of truth. Translates [DESIGN.md](./DESIGN.md) and the [ADRs](./docs/adr/) into a concrete Swift/SwiftUI architecture: deployment target, app shape, view hierarchy, state machine, integrations, and dependencies. **No Swift code in this document** — it describes types, file responsibilities, and integration points. The next step ([PLAN.md](./PLAN.md)) breaks this into atomic build tasks.

Upstream: [PRD.md](./PRD.md) · [CONTEXT.md](./CONTEXT.md) · [docs/adr/](./docs/adr/) · [DESIGN.md](./DESIGN.md)

---

## 1. Deployment target & platform

- **Minimum macOS: 14 (Sonoma).**
- **Recommended build target: macOS 15 (Sequoia)**, run-conditional `#available(macOS 15, *)` for any 15-only API used.
- Architecture: universal binary (Apple Silicon primary; Intel as polite courtesy — llama-server still runs on Intel, just slower).

Why macOS 14: gives the Observation framework (`@Observable`, `@Bindable`), the `@Entry` environment macro, `SettingsLink`, `windowIdealPlacement` (15+ only), and modern SwiftUI text APIs. Drops Ventura — fine for the r/LocalLLaMA audience on M-series Macs running current OS.

Why not macOS 15: would lock out Sonoma users for marginal API gain. Reconsider at Phase 2.

---

## 2. App architecture

**Hybrid: SwiftUI App protocol as the entry point + AppKit interop for the floating panel.**

The panel is the only piece that needs AppKit (NSPanel is not directly expressible as a SwiftUI Scene). Everything else — first-run, settings, menu-bar status item — is pure SwiftUI scenes.

### 2.1 App-level shape

```
@main LocalpenApp : App
├── @NSApplicationDelegateAdaptor — bridges to AppDelegate for AppKit-only concerns
├── @State appState: AppState — global @Observable
├── Scenes:
│   ├── Window("First Run", id: "first-run") { FirstRunView() }
│   │     — shown on launch if AX permission missing OR no model installed
│   ├── Settings { SettingsView() }
│   │     — Cmd+, opens; hotkey recorder + model picker + history controls
│   └── MenuBarExtra("Localpen", systemImage: "pencil.tip") { StatusMenu() }
│         — small status menu: open settings, open panel, quit
└── (Floating panel) — NOT a SwiftUI scene; managed by AppDelegate via PanelController
```

The floating panel does not live in `body: some Scene`. It is instantiated by `AppDelegate.applicationDidFinishLaunching` as an `NSPanel` subclass and shown/hidden by the `PanelController` in response to hotkey events.

### 2.2 Why this split

- `WindowGroup` and `Window` SwiftUI scenes don't expose the `NSPanel` style mask or non-activating focus behavior we need.
- Wrapping the entire app in AppKit (no SwiftUI App protocol) is more code, harder to compose, and loses modern Scene types like `Settings` and `MenuBarExtra`.
- The hybrid pattern is well-trodden — Raycast, Granola, Things 3 all use it.

### 2.3 Info.plist keys

- `LSApplicationCategoryType` = `public.app-category.productivity`
- `NSAppleEventsUsageDescription` — only if we end up needing AppleEvents (we don't in Phase 1)
- `LSUIElement` = **false** — show a Dock icon (debatable; see §2.4)
- `LSMinimumSystemVersion` = `14.0`
- Bundle ID: `app.localpen.Localpen` or similar; commit before first signed build.

### 2.4 Dock icon question

DESIGN.md doesn't take a position. My recommendation: **Phase 1 ships with a Dock icon.** Reasons: discoverable, easier to grant AX permission to (System Settings shows Dock-icon apps prominently), the audience expects it. Reconsider in Phase 3 when audience widens — menu-bar-only might fit the non-technical user better.

---

## 3. State management

**Use the Observation framework (`@Observable`). All observable classes annotated `@MainActor`.**

### 3.1 Top-level observable types

| Type | Purpose | Ownership |
|---|---|---|
| `AppState` | Server status, current model, AX permission state, history-write toggle | `@State` in `LocalpenApp` |
| `PanelState` | The panel state machine (S1-S7) | `@State` in `PanelController` |
| `ModelRegistry` | Loaded TOML model catalog + active model selection | `@State` in `AppState` |
| `HotkeyConfig` | Current global hotkey binding | `@State` in `AppState` |
| `Persistence` | GRDB database queue + interactions schema | Injected via `@Environment` |
| `LlamaServerController` | Subprocess lifecycle + health | Injected via `@Environment` |

### 3.2 Property wrapper conventions (per state-management.md)

- `@State private var` for view-owned state.
- `@Observable` classes injected via `@Environment(Type.self)`.
- `@Bindable` when a child view needs bindings to an injected `@Observable`.
- `@ObservationIgnored @AppStorage` for any UserDefaults-backed property inside an `@Observable` class.
- `@FocusState private var` for keyboard focus state inside views.

### 3.3 Threading

- `@MainActor` on all observable classes.
- llama-server subprocess I/O, file downloads, SQLite writes happen off-main; results dispatched back to main via `Task { @MainActor in ... }`.

---

## 4. The panel — NSPanel configuration

### 4.1 Answering DESIGN.md §8 Q1 (style mask)

Create a custom `NSPanel` subclass `FloatingPanel`. Initializer config:

| Property | Value | Reason |
|---|---|---|
| `styleMask` | `[.nonactivatingPanel, .titled, .fullSizeContentView]` | `.nonactivatingPanel` so we don't steal key focus from the source app. `.titled` is required for proper window behavior; we hide the title bar visually via `.fullSizeContentView` + transparent titlebar. Borderless windows lose some macOS niceties (drag, NSWindow management) — keep `.titled` and hide the chrome instead. |
| `titlebarAppearsTransparent` | `true` | Visual title bar disappears, but window still has all its plumbing. |
| `titleVisibility` | `.hidden` | No title text. |
| `isMovableByWindowBackground` | `true` | User drags the panel from any non-interactive region. |
| `hasShadow` | `true` | Native drop shadow (DESIGN.md §2.5 elevation). |
| `backgroundColor` | `.clear` | The SwiftUI panel-bg color paints the background; let SwiftUI own the visual. |
| `isOpaque` | `false` | Required when `backgroundColor` is `.clear`. |
| `level` | `.floating` | Above normal windows; below modal dialogs. |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary]` | Available in fullscreen apps; follows the user across Spaces. |
| `becomesKeyOnlyIfNeeded` | `true` | Doesn't grab key window status from the source app. |
| `worksWhenModal` | `false` | Phase 1 default; revisit if we want the panel to appear over modal dialogs. |
| `isReleasedWhenClosed` | `false` | We re-show the same instance across hotkey presses. |
| `contentMinSize` | `CGSize(width: 360, height: 200)` | Per DESIGN.md §3.1. |
| `contentMaxSize` | `CGSize(width: 360, height: 480)` | Locked width, capped height. |

### 4.2 Hosting SwiftUI inside

The panel's `contentView` is an `NSHostingView<PanelView>` (the SwiftUI root). `PanelView` reads `@Environment(PanelState.self)` to render the appropriate sub-view per state.

Window corner radius (10pt per DESIGN.md §2.5) — set on the `contentView.layer` via a custom NSView wrapper, since NSPanel itself doesn't directly expose corner radius for hosted SwiftUI content. The `FloatingPanel` subclass configures this in `awakeFromNib` or its initializer.

### 4.3 Per-bundle-ID anchor store (DESIGN.md §8 Q2)

**Recommendation: UserDefaults, not SQLite.**

Reasoning: anchor data is small (one CGRect per source app), only read on hotkey, only written when user drags the panel. UserDefaults is the right scale. SQLite would be overkill and introduces a synchronization story with the interactions database that we don't need.

Shape:

- Key: `"PanelAnchors"`
- Value: `[String: [String: CGRect]]` JSON-encoded — outer key = source-app bundle ID, inner key = display UUID (so multi-display anchors work), value = the panel's frame for that combination.
- `AnchorStore` service owns the read/write. Read on `panelWillShow(forBundleID:onDisplay:)`. Write on panel's `windowDidMove` notification.

Default placement (no stored anchor): right edge of the current display, vertically centered, 24pt margin. Implemented in `AnchorStore.defaultPlacement(onDisplay:)`.

---

## 5. View hierarchy decomposition

All SwiftUI views inside the panel. File-per-view convention.

| File | View type | Responsibility |
|---|---|---|
| `Panel/PanelView.swift` | `PanelView: View` | Root view inside `NSHostingView`. Switches on `PanelState` to render the appropriate sub-view. Owns no state — reads from `@Environment(PanelState.self)`. |
| `Panel/SelectionBlock.swift` | `SelectionBlock: View` | Renders the quote-rule + selection text + source-app metadata. Stateless. Takes `Selection` value. |
| `Panel/ActionMenuView.swift` | `ActionMenuView: View` | The 6-row action list. Manages `@FocusState` for which row is focused. Calls `onPick(Action)` callback. |
| `Panel/ActionRow.swift` | `ActionRow: View` | One row: label + focus indicator (2pt accent left-rail + tinted bg). Takes `Action` + `isFocused`. |
| `Panel/CustomPromptView.swift` | `CustomPromptView: View` | The Custom textarea + footer. Owns a `@State` `String` for the prompt. Calls `onSubmit(String)`. |
| `Panel/ResultView.swift` | `ResultView: View` | Streaming and result-display region. Owns a `@State` for whether editing is active. Toggles between display mode (streaming caret) and edit mode. |
| `Panel/ResultToolbar.swift` | `ResultToolbar: View` | The bottom strip below the result — action pill + hint cluster. Stateless. |
| `Panel/PanelFooter.swift` | `PanelFooter: View` | The bottom hint strip for the menu state ("↑↓ select · ↩ apply · esc dismiss"). Stateless. |
| `Panel/ErrorBanner.swift` | `ErrorBanner: View` | Error template — single-line message + action button. Takes `PanelError` enum value. |
| `Panel/StreamingCaret.swift` | `StreamingCaret: View` | The 7×16pt blinking accent caret. Encapsulates the animation. |
| `FirstRun/FirstRunView.swift` | `FirstRunView: View` | The first-run window root. Switches between permission-ask and model-download sub-states. |
| `FirstRun/PermissionAskView.swift` | `PermissionAskView: View` | S1 content. |
| `FirstRun/ModelDownloadView.swift` | `ModelDownloadView: View` | S2 content with progress bar. |
| `Settings/SettingsView.swift` | `SettingsView: View` | TabView with General + Model + History tabs. |
| `Settings/HotkeyRecorderView.swift` | `HotkeyRecorderView: View` | Hosts `KeyboardShortcuts.Recorder` for chord recording (SwiftUI-native, no `NSViewRepresentable` needed — see [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md)). |
| `Settings/ModelPickerView.swift` | `ModelPickerView: View` | List of models from `ModelRegistry` with download status. |
| `MenuBar/StatusMenu.swift` | `StatusMenu: View` | The MenuBarExtra dropdown contents. |

### 5.1 View extraction notes (per view-structure.md)

- Each panel state sub-view is its own type. The `PanelView`'s switch statement is short and readable.
- `ActionRow` is extracted from `ActionMenuView` to keep the ForEach simple and stable.
- No nested observables; injection happens at the panel root and reaches sub-views via `@Environment`.

---

## 6. Panel state machine (S1–S7 in Swift)

```text
PanelState (enum, @Observable wrapper):
  .hidden
  .firstRun(FirstRunStep)           ← S1, S2 (in the dedicated window, NOT the floating panel)
  .empty                            ← S3
  .captured(Selection)              ← S4
  .customPrompt(Selection?)         ← S4 sub-state when Custom is picked
  .generating(Selection?, Action, partialResult: String)
                                    ← S5
  .result(Selection?, Action, finalResult: String, isEditing: Bool)
                                    ← S6
  .error(PanelError)                ← S7
```

`FirstRunStep` is an inner enum: `.permission` / `.download(bytesDone: Int64, bytesTotal: Int64)` / `.complete`.

`Action` is an enum: `.proofread / .polish / .moreFormal / .moreCasual / .shorter / .custom(String)`.

`PanelError` is an enum with associated values for the 6 cases in DESIGN.md §S7.

`Selection` is a struct: `text: String`, `sourceBundleID: String?`, `sourceAppName: String?`.

### 6.1 Transitions

| From | Trigger | To |
|---|---|---|
| `.hidden` | hotkey + selection captured | `.captured(Selection)` |
| `.hidden` | hotkey + no selection | `.empty` |
| `.captured` | arrow keys | `.captured` (focus moves; not a state change — focus is `@FocusState` inside `ActionMenuView`) |
| `.captured` | Return on action ≠ Custom | `.generating(selection, action, "")` |
| `.captured` | Return on Custom | `.customPrompt(selection)` |
| `.empty` | Return on Custom input | `.customPrompt(nil)` then `.generating(nil, .custom(text), "")` |
| `.customPrompt` | submit | `.generating(selection, .custom(text), "")` |
| `.customPrompt` | backspace on empty | `.captured(selection)` |
| `.generating` | token received | `.generating(selection, action, partial+token)` |
| `.generating` | stream complete | `.result(selection, action, partial, isEditing: false)` |
| `.generating` | stream error | `.error(.timeout / .serverDown / ...)` |
| `.result` | ⌘↩ | (side effect: paste-back) → `.hidden` |
| `.result` | ⌫ | `.captured(selection)` |
| `.result` | click in text | `.result(...isEditing: true)` |
| `.error` | retry | (re-enter prior state) |
| (any) | Esc | `.hidden` |

State changes happen via methods on `PanelController` (the controller that owns the `PanelState`). Views call into the controller via injected closures or `@Environment` actions.

### 6.2 Operation class and the Respond action (ADR 0009)

**`Action.OperationClass`** is a two-case enum nested in or alongside `Action`:

- `.revise` — the result is a revised version of the captured selection; paste-back applies.
- `.create` — the result is a new artifact (e.g. a reply); paste-back does not apply; the result copies to the clipboard.

Every `Action` case carries a computed `operationClass: OperationClass` property. The existing five transforms plus `.custom` are `.revise`. The new `.respond` case is `.create`.

**Updated `Action` enum.** The full Phase 1 set is: `.proofread / .polish / .moreFormal / .moreCasual / .shorter / .custom(String) / .respond`. The `Action` enum must be `Identifiable` and `Hashable` (stable for `ForEach`).

**`PanelContext.action` invariant.** The `.customPrompt` state always carries its pending action explicitly in `PanelContext` (or as an associated value on `.customPrompt`) so `submitCompose` can route via `Action.fromCompose(_:context:)` without re-inferring intent at submit time.

**`submitCompose` routing.** `PanelController.submitCompose(text:)` delegates to `Action.fromCompose(_:context:)`, which returns the appropriate `Action` based on the compose context (Custom → `.custom(text)`, Respond compose path → `.respond` with optional steer). This keeps routing logic in the model layer, not in the view.

**Class-aware `acceptResult`.**  `PanelController.acceptResult(result:)` branches on `action.operationClass`:

- `.revise` → call `TextIO.pasteBack(result)` → dismiss. (Existing behavior.)
- `.create` → place `result` on `NSPasteboard.general` → dismiss without paste-back. No `TextIO.pasteBack` call.

The result-toolbar view reads `action.operationClass` to select the correct footer hint copy (see DESIGN.md §3.4 and §6).

**`styleContext` Phase 2 seam.** `ActionPrompts` exposes a `styleContext: String?` parameter on the Respond prompt builder. Phase 1 always passes `nil`; Phase 2 will supply a voice/style string derived from the inferred-style store (ADR 0006 memory layer). The parameter is present in Phase 1 to avoid a call-site change when Phase 2 populates it.

**Disabled-row invariant.** `ActionMenuView` disables and skips `.respond` in keyboard focus when `PanelState` is `.empty` (no captured selection). The `Action.respond` case has a computed `requiresSelection: Bool = true` property that `ActionMenuView` checks to determine disablement.

---

## 7. Streaming-result rendering (DESIGN.md §8 Q3)

**Recommendation: SwiftUI `TextEditor` with a String binding for editable state; SwiftUI `Text` during streaming.**

Rationale:

- During streaming: the result is appended-to and the user shouldn't edit yet. Use a non-interactive `Text` showing `result` + a `StreamingCaret` view appended via HStack.
- After streaming completes: replace `Text` with `TextEditor(text: $result)` for editability. The streaming caret disappears; the system text caret takes over on focus.
- TextEditor's plain-String binding is sufficient — no rich text, no Genmoji, no AttributedString in Phase 1.

A future Phase 2 might want NSTextView for find-in-text, custom selection behavior, or rich text. Not Phase 1.

The state machine handles the transition: `.generating` renders the `Text`+`StreamingCaret` path; `.result(isEditing: false)` renders a tappable display that switches to `.result(isEditing: true)` (TextEditor) on click.

### 7.1 Selection-block scrolling (DESIGN.md §8 Q6)

Selection text wraps inside a `ScrollView(.vertical, showsIndicators: false)` with `.frame(maxHeight: 80)` (approximately 4 lines at 13pt/1.5 line-height). The overall panel size is fixed; the selection scrolls inside its region. SwiftUI's native scroll bounces appropriately, and `showsIndicators: false` plus the system overlay-scroll preference means no permanent scrollbar.

---

## 8. llama-server subprocess lifecycle

`Services/LlamaServer.swift` — `@Observable @MainActor` controller.

### 8.1 Binary location

The `llama-server` binary is bundled inside the .app at `Localpen.app/Contents/Resources/llama-server`. Built ahead of time from a pinned llama.cpp tag (per PRD's "pin to monthly snapshots, don't chase HEAD" risk mitigation).

### 8.2 Lifecycle states

```
LlamaServerState:
  .stopped
  .starting(pid: Int32)
  .ready(port: Int, modelID: String)
  .crashed(reason: String)
```

### 8.3 Spawning

Use Foundation's `Process` API. Arguments include:

- `--model <path-to-GGUF-in-application-support>`
- `--host 127.0.0.1`
- `--port 11434` (Localpen-default; collide-detect and increment if needed)
- `--ctx-size 4096` (configurable per model in models.toml)
- `--gpu-layers 999` (offload everything to Metal on Apple Silicon; llama.cpp clamps appropriately)
- `--mlock` (keep model in memory)

stdout/stderr piped to in-memory ring buffers for the diagnostics view (Phase 2; in Phase 1, log to file under `~/Library/Logs/Localpen/`).

### 8.4 Health & restart

- After spawn, poll `GET http://127.0.0.1:<port>/health` every 200ms with a 5s timeout. Transition `.starting` → `.ready` on first successful health response.
- During `.ready`, no active health-check; assume up. Stream requests will surface crashes via connection errors.
- On crash (connection refused, exit signal), transition to `.crashed`. Optionally auto-restart once; on second crash within 60s, surface `.error(.serverDown)` in PanelState.
- Process terminated on app quit (`applicationWillTerminate` in AppDelegate).

### 8.5 Streaming API

`Services/StreamingClient.swift` wraps the llama-server's `/completion` (or `/v1/chat/completions` for OpenAI-compat) endpoint with `stream: true`. Use `URLSession.bytes(for:)` to get an `AsyncBytes` stream; parse SSE events as they arrive, decode each chunk's token, append to `PanelState.generating(..., partial)`.

```text
StreamingClient.complete(prompt: String, action: Action) -> AsyncThrowingStream<String, Error>
```

Each yield is a token string; consumer in `PanelController` accumulates into `partial` and updates state on main.

---

## 9. Clipboard-mediated text I/O (ADR 0003 in Swift)

`Services/TextIO.swift` — single module owning the capture/paste-back mechanic.

### 9.1 Capture flow

1. `captureSelection() async throws -> Selection?`
2. Steps inside:
   - `savedFrontmostApp = NSWorkspace.shared.frontmostApplication` (the `NSRunningApplication`)
   - `savedPasteboardItems = NSPasteboard.general.pasteboardItems?.compactMap { ... }` — copy out each item's types + data
   - Post synthetic ⌘C via `CGEvent`:
     - `CGEventSource(stateID: .hidSystemState)`
     - `cmdDown = CGEvent(keyboardEventSource:source, virtualKey: 0x37, keyDown: true)` (Command = `kVK_Command` = 0x37)
     - `cDown = CGEvent(keyboardEventSource:source, virtualKey: 0x08, keyDown: true)` (C = `kVK_ANSI_C` = 0x08); set `cDown.flags = .maskCommand`
     - `cUp = CGEvent(...keyDown: false)`; set `cUp.flags = .maskCommand`
     - `cmdUp = CGEvent(...Command, keyDown: false)`
     - `post(tap: .cghidEventTap)` for each, in order
   - Sleep ~50ms (`try await Task.sleep(for: .milliseconds(50))`)
   - Read `NSPasteboard.general.string(forType: .string)`
   - If pasteboard unchanged or no string, return nil → PanelState `.empty`
   - Otherwise, restore pasteboard? **No — we keep our captured string on pasteboard for the duration of the panel session.** We restore the original pasteboard at panel-dismiss time (whether successful paste-back or not).
   - Build `Selection(text:, sourceBundleID: savedFrontmostApp.bundleIdentifier, sourceAppName: savedFrontmostApp.localizedName)`. Cache `savedFrontmostApp` for later re-activation.

### 9.2 Paste-back flow

1. `pasteBack(result: String) async`
2. Steps:
   - `NSPasteboard.general.clearContents()` then `setString(result, forType: .string)`
   - `savedFrontmostApp.activate(options: [])` — bring source app to front
   - Sleep ~80ms (let activation land before posting paste)
   - Post synthetic ⌘V via same CGEvent pattern (virtual key `kVK_ANSI_V` = 0x09)
   - Sleep ~120ms (let paste land)
   - Restore original pasteboard from `savedPasteboardItems` — clear and re-populate each saved type's data.

### 9.3 Paste-back failure detection (DESIGN.md §8 Q4)

**Phase 1 ships without runtime detection of paste-back failure.**

There is no reliable signal on macOS to know whether a synthetic ⌘V resulted in text appearing in the target app's text field. AX tree-walking could check (per ADR 0003 we deliberately don't), and even that's unreliable in Electron. Pasteboard state doesn't change on paste.

**Phase 1 mitigation:** maintain a small allow/deny list keyed by source-app bundle ID:

- `Resources/known-bad-paste-apps.toml` (ships with the app, user-extensible)
- If the source app's bundle ID matches an entry: skip the synthetic ⌘V entirely. Show `.error(.pasteBackFallback)` with the message from DESIGN.md S7: "Result copied. Press ⌘V in your app." Result is already on the pasteboard. User does manual paste.

Phase 2 candidate: heuristic detection using NSWorkspace `didActivateApplicationNotification` timing + a small AX read just-in-time (the only AX tree-walk we'd do; gated behind a Power-User toggle "Best-effort paste verification").

### 9.4 Permissions

CGEvent posting requires the Accessibility permission. Check on app launch via `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: false])`. If not granted, route to `.firstRun(.permission)`.

---

## 10. Global hotkey (KeyboardShortcuts)

`Services/HotkeyService.swift` wraps `sindresorhus/KeyboardShortcuts`. See [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md) for the swap rationale (MASShortcut's only tagged release predates its SPM support).

### 10.1 Default binding

`⌃⌥Space` (Control + Option + Space) per DESIGN.md §5.4.

Declared as a typed `KeyboardShortcuts.Name`:

```text
extension KeyboardShortcuts.Name {
    static let toggleLocalpen = Self("toggleLocalpen",
        default: .init(.space, modifiers: [.control, .option]))
}
```

Persistence is library-managed (keyed by the `Name`'s raw string), so no UserDefaults bridge needed.

### 10.2 Registration

- On app launch: `KeyboardShortcuts.onKeyDown(for: .toggleLocalpen) { ... }` registers the callback.
- On hotkey fire: `PanelController.toggleFromHotkey()` — capture selection and show panel, or dismiss if visible.
- Conflict surfacing: `KeyboardShortcuts.Recorder` shows in-line conflicts in the Settings UI; no explicit `Validator` call needed in M1.

### 10.3 Chord recorder UI for Settings

`KeyboardShortcuts.Recorder("Toggle Localpen:", name: .toggleLocalpen)` is a SwiftUI `View` — no `NSViewRepresentable` wrapper required. `Settings/HotkeyRecorderView.swift` is a thin SwiftUI view hosting the Recorder; container styling matches the rest of the Settings tab.

---

## 11. Interactions persistence (ADR 0006 in Swift)

`Services/Persistence.swift` — GRDB-based.

### 11.1 SPM dependency

**GRDB.swift** (`https://github.com/groue/GRDB.swift`). Reasons over SQLite.swift:

- More actively maintained.
- Native async/await support (`DatabaseWriter` async methods).
- Better Swift-native API (Codable record types, value observation, migrations).
- Used by other indie Mac apps in the same category (Raycast extensions, NetNewsWire, others).

### 11.2 Database location

`~/Library/Application Support/Localpen/history.sqlite`. Created on first launch if absent.

### 11.3 Swift record type

```text
Interaction:
  id: Int64                  ← INTEGER PRIMARY KEY AUTOINCREMENT
  timestamp: Date            ← INTEGER (unix epoch seconds)
  sourceApp: String?         ← TEXT, source bundle ID
  selection: String?         ← TEXT
  action: String             ← TEXT, the action raw value
  customPrompt: String?      ← TEXT
  modelID: String            ← TEXT
  modelOutput: String?       ← TEXT
  accepted: Bool             ← INTEGER 0/1
  editedOutput: String?      ← TEXT
```

Conforms to `FetchableRecord, PersistableRecord`. Table created via `DatabaseMigrator` registered on first launch (migration ID: `v1.create_interactions`).

### 11.4 Write path

`PanelController.acceptResult()` builds an Interaction, calls `persistence.save(_:)`. The save is async (off-main thread); user does not wait.

Edge case: app quits while a save is in flight — `applicationWillTerminate` awaits the persistence queue's pending writes (with a short timeout) before exit.

### 11.5 Read path

Phase 1 has no read path used by the running app. Settings exposes:

- "Clear history" — `DELETE FROM interactions;` after confirm dialog
- "Export history" — `SELECT *` rendered to JSON and saved via `fileExporter`

Phase 2's memory inference will read; not Phase 1's concern.

---

## 12. Model registry & config (ADR 0005 in Swift)

`Services/ModelRegistry.swift` + `Resources/models.toml`.

### 12.1 SPM dependency

**TOMLKit** (`https://github.com/LebJe/TOMLKit`). Reasons:

- TOML is the most human-readable config format among reasonable Swift options. JSON5 has weaker tooling; YAML has whitespace gotchas; plain JSON disallows comments.
- TOMLKit is actively maintained, Codable-friendly.

### 12.2 Schema (sketch)

```toml
[[models]]
id = "qwen-2.5-7b-instruct-q4-km"
name = "Qwen 2.5 7B Instruct"
download_url = "https://huggingface.co/.../qwen2.5-7b-instruct-q4_k_m.gguf"
download_size_bytes = 4685892608
sha256 = "..."
context_size = 4096
chat_template = "chatml"
default = true

[models.prompts]
proofread = "..."
polish = "..."
more_formal = "..."
more_casual = "..."
shorter = "..."

[models.sampling]
temperature = 0.4
top_p = 0.9
repeat_penalty = 1.05

[[models]]
id = "llama-3.1-8b-instruct-q4-km"
name = "Llama 3.1 8B Instruct"
download_url = "..."
# ...
```

### 12.3 Lookup & download

- App boot: load `models.toml` from `Bundle.main` (read-only baseline) AND from `~/Library/Application Support/Localpen/models.toml` (user overrides, if present). User overrides win.
- The "Use a different model" UI from S2 / Settings shows the list, marks installed vs. not-installed by checking presence of the GGUF at `~/Library/Application Support/Localpen/models/<id>.gguf`.
- Selecting a non-installed model triggers download via `URLSession.downloadTask`. Resumable on quit-and-relaunch.

### 12.4 Hardware fingerprint (ADR 0005)

`Services/HardwareFingerprint.swift`:

- `sysctl hw.model` for Mac model identifier ("Mac15,3" etc.)
- `sysctl hw.machine` for architecture ("arm64")
- `ProcessInfo.processInfo.physicalMemory` for total unified memory
- Disk free via `FileManager.default.attributesOfFileSystem(forPath:)` → `.systemFreeSize`

Collected once on first launch, written to `~/Library/Application Support/Localpen/hardware.json`. No telemetry; just sits on disk for Phase 2 auto-pick to consume.

---

## 13. File structure

Approximate layout. Adjust as the project grows. Xcode project, not SPM package (Xcode app target needs the project format).

```
Localpen/
├── Localpen.xcodeproj
├── Localpen/
│   ├── LocalpenApp.swift               — @main, Scenes
│   ├── AppDelegate.swift               — NSApplicationDelegate, AX check, panel lifecycle
│   ├── Models/
│   │   ├── AppState.swift              — top-level @Observable
│   │   ├── PanelState.swift            — state machine enum + controller
│   │   ├── Action.swift                — 6-case enum
│   │   ├── Selection.swift             — captured-text struct
│   │   ├── Interaction.swift           — GRDB record
│   │   ├── ModelDescriptor.swift       — TOML-decoded model entry
│   │   ├── HotkeyConfig.swift          — chord + UserDefaults bridge
│   │   └── PanelError.swift            — error enum + retry semantics
│   ├── Panel/
│   │   ├── FloatingPanel.swift         — NSPanel subclass
│   │   ├── PanelController.swift       — bridge between NSPanel + SwiftUI + state
│   │   ├── PanelView.swift             — SwiftUI root
│   │   ├── SelectionBlock.swift
│   │   ├── ActionMenuView.swift
│   │   ├── ActionRow.swift
│   │   ├── CustomPromptView.swift
│   │   ├── ResultView.swift
│   │   ├── ResultToolbar.swift
│   │   ├── PanelFooter.swift
│   │   ├── ErrorBanner.swift
│   │   └── StreamingCaret.swift
│   ├── FirstRun/
│   │   ├── FirstRunView.swift
│   │   ├── PermissionAskView.swift
│   │   └── ModelDownloadView.swift
│   ├── Settings/
│   │   ├── SettingsView.swift
│   │   ├── HotkeyRecorderView.swift    — SwiftUI view hosting KeyboardShortcuts.Recorder
│   │   ├── ModelPickerView.swift
│   │   └── HistorySettingsView.swift   — clear / export
│   ├── MenuBar/
│   │   └── StatusMenu.swift
│   ├── Services/
│   │   ├── LlamaServerController.swift — subprocess lifecycle
│   │   ├── StreamingClient.swift       — URLSession bytes → AsyncThrowingStream
│   │   ├── TextIO.swift                — synthetic ⌘C / ⌘V, pasteboard save/restore
│   │   ├── HotkeyService.swift         — KeyboardShortcuts wiring
│   │   ├── Persistence.swift           — GRDB stack + migrations
│   │   ├── AnchorStore.swift           — per-bundle-ID panel positions
│   │   ├── ModelRegistry.swift         — TOML load + active selection
│   │   └── HardwareFingerprint.swift   — sysctl + memory probe
│   ├── DesignSystem/
│   │   ├── Tokens.swift                — Color + spacing constants from DESIGN.md §2
│   │   ├── Motion.swift                — easing curves + durations
│   │   └── Typography.swift            — font configurations
│   └── Resources/
│       ├── models.toml                 — bundled model registry
│       ├── known-bad-paste-apps.toml   — paste-back deny-list (per §9.3)
│       ├── Info.plist
│       ├── Assets.xcassets/            — app icon, no other images
│       └── llama-server                — the binary (prebuilt, per §8.1)
└── LocalpenTests/                      — unit tests (Phase 1 scope: TextIO, Persistence, ModelRegistry)
```

Total: ~30 Swift files for Phase 1. Tracks with the design's six-state UI + four-service backend split.

---

## 14. SPM dependencies (summary)

| Package | Purpose | Notes |
|---|---|---|
| `KeyboardShortcuts` | Global hotkey + chord recorder UI | Pure Swift, SwiftUI-native Recorder. SPM-native. See [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md). |
| `GRDB.swift` | SQLite with Swift-native API | Active maintenance; async/await. |
| `TOMLKit` | TOML parsing for model registry | Lightweight, Codable. |

**Not added** (intentionally):
- `llama.cpp` as a library: we subprocess `llama-server` per PRD architecture, not link to libllama.
- Networking/Alamofire/etc.: URLSession is sufficient.
- Logging frameworks: Apple's `os.log` (modern: `Logger`) is sufficient.
- Crash reporting: not Phase 1 scope (consider Sentry / Bugsnag in Phase 2).

---

## 15. Answers to DESIGN.md §8 open questions (consolidated)

| Question | Answer | Section |
|---|---|---|
| Q1: NSPanel style mask | `[.nonactivatingPanel, .titled, .fullSizeContentView]` + `titlebarAppearsTransparent` + `titleVisibility = .hidden` | §4.1 |
| Q2: Anchor store mechanism | UserDefaults JSON (`[String: [String: CGRect]]`), not SQLite | §4.3 |
| Q3: SwiftUI Text vs NSTextView for result | `Text` during streaming; `TextEditor(text: $result)` when editable | §7 |
| Q4: Detect ⌘V failure | Phase 1 ships without runtime detection; allow/deny list by bundle ID handles known-bad apps; deferred to Phase 2 for heuristic | §9.3 |
| Q5: Hotkey chord recorder UI | `KeyboardShortcuts.Recorder` (native SwiftUI view) — no `NSViewRepresentable` wrapper needed | §10.3 |
| Q6: Selection tall-content behavior | Selection scrolls inside a fixed-height region; panel itself stays at content-fit ≤ 480pt | §7.1 |

---

## 16. What this spec deliberately does NOT include

- **Test plan.** Phase 1 testing strategy is light — unit tests for TextIO (clipboard save/restore round-trip), Persistence (migration + write/read), ModelRegistry (TOML parsing). No UI tests in Phase 1. Defer to PLAN.md.
- **CI/CD.** GitHub Actions, signing, notarization scripts — not in this design contract. Build/release process gets its own doc when we're ready to ship.
- **Sparkle integration.** Mentioned in PRD as the update mechanism but not load-bearing for Phase 1 first build. Add when we cut a real `.dmg`.
- **Telemetry / analytics.** Out of scope; local-first principle.
- **Crash reporting.** Out of scope for Phase 1.
- **Localization.** Phase 1 ships English-only. All strings in Localizable.strings ready for future i18n, but no translations.
- **Phase 1.5 conversational surface.** Separately specified when Phase 1 ships.

---

## 17. Correctness checklist (per skill operating rules)

- [x] `@State` properties marked `private` throughout the spec.
- [x] `@Binding` only where children modify parent state — none used in the spec; observables flow via Environment.
- [x] Passed values not declared as `@State` — observables injected via Environment.
- [x] `@Observable` with `@State` ownership; `@Bindable` for injected with bindings.
- [x] No deprecated APIs from `references/latest-apis.md` — uses `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, `animation(_:value:)`, `onChange(of:)` no-param closure, `@Observable`, `@Entry`.
- [x] `ForEach` over action list uses stable identity (Action enum is Hashable + Identifiable).
- [x] Constant view count per ForEach element.
- [x] `animation(_:value:)` will always include `value:` parameter.
- [x] `@FocusState` properties marked `private` in ActionMenuView spec.
- [x] No iOS 26+ APIs in Phase 1 (we don't adopt Liquid Glass per the skill rule "Only adopt Liquid Glass when explicitly requested by the user").

---

## 18. Out-of-spec engineering decisions deferred to PLAN.md

The implementation plan should answer:

1. **Build order** (tracer-bullet first, per DESIGN-BRIEF.md §5).
2. **First app target** to validate the slab against (TextEdit is easiest; Slack is the highest-value validation).
3. **Test data for the action prompts** — what selection text + expected behavior anchors do we use to validate that Qwen 2.5 7B follows each system prompt reliably?
4. **Distribution channel** for Phase 1 (.dmg via GitHub Releases is the assumption; verify Homebrew cask is not Phase 1).
5. **Beta cohort** — who tests Phase 1 before HN announcement? r/LocalLLaMA private testers?
