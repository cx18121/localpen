# Localpen Phase 1 — DESIGN.md

Production-ready design spec for the Phase 1 NSPanel. Source of truth for the swiftui-expert translation pass.

Upstream: [PRD.md](./PRD.md) · [CONTEXT.md](./CONTEXT.md) · [docs/adr/](./docs/adr/) · [DESIGN-BRIEF.md](./DESIGN-BRIEF.md) · [sketches/](./sketches/) (throwaway prototype, layout direction committed = **A**).

> **Polish pass (2026-05, evolved from the original spec).** After the first build, the panel was refined toward a more native, less cramped feel. Changes that supersede the original spec below:
> - **Vibrancy adopted now** (was deferred to Phase 2): the panel surface is an `NSVisualEffectView` — `.hudWindow` in dark, `.popover` in light — behind a contrast tint (`panelTint`), with a glass top-edge and Reduce Transparency fallback. This overrides §3.1's "opaque, no vibrancy" and the §7 exclusion.
> - **Wider + more breathing room:** panel width 360 → **400pt**; reading type bumped (selection/menu 13 → 14, result 14 → 15, footer 11 → 12); action rows 32 → 38pt.
> - **Placement:** fixed right-edge sidebar, **top-edge-anchored** so it sizes to content without jumping vertically (replaces §3.2's per-source-app last-anchored store, which was removed).
> - **Motion:** entrance slides in from the right + fades; the action-menu focus is a single highlight that **slides** between rows. Both honor Reduce Motion.
> - **Streaming** text lives in `PanelController.streamingText` and renders via `StreamingResultView`, so tokens re-render only the result region.
> - **Keyboard/focus model:** `Tab` cycles focus (input ↔ action menu; `Tab` also enters the result to edit). The input auto-focuses on open **only in the empty state** — when text is captured the menu keeps focus so `Return` still picks an action immediately. `⌘C` copies the result without pasting back. **`⌫` "try another" was dropped** (Esc is the only back path) — supersedes §5.1/§3.4/§6. Shortcut hints render key glyphs in a mono style (`KbdHint`).

---

## 1. Identity in one paragraph

Localpen's panel is a quiet, anchored macOS surface that appears in 180ms, captures what you've selected, offers six precise actions, streams a result, and disappears — sitting alongside whatever app you were already writing in. It does not announce itself. It does not decorate. It coexists with Slack's purple chrome, Cursor's magenta, Mail's blue, by being almost monochrome and almost still. The only color note is a single low-chroma blue, drawn from the neutrals' own blue family so it reads as the surface "lit up" rather than a separate hue — used for active focus and the streaming caret, never for decoration. The voice is terse, native, slightly understated. The tool disappears into the task.

Anchors: Granola (form factor), Raycast (latency aesthetic), Things 3 (native-macOS polish floor).
Anti-references: Apple Writing Tools' system-tooltip feel, ChatGPT Mac chrome, Electron command-bar typography.

---

## 2. Visual tokens

All colors expressed in OKLCH. Never `#000` or `#fff`. Every neutral tinted toward the cool brand hue (`240°`).

### 2.1 Dark theme (primary aesthetic vision)

| Role | Token | Value | Notes |
|---|---|---|---|
| Workspace background | `--bg-workspace` | `oklch(0.16 0.005 240)` | Reference only — not part of the panel itself. Used for design context. |
| Panel surface | `--panel-bg` | `oklch(0.22 0.008 240)` | Body of the panel. |
| Panel surface 2 (footer / chrome) | `--panel-bg-2` | `oklch(0.24 0.009 240)` | Slightly lighter; used for the result-toolbar strip + hint footer. |
| Panel border (1px hairline) | `--panel-border` | `oklch(0.32 0.012 240)` | Outer panel edge. |
| Section divider (1px) | `--panel-hairline` | `oklch(0.28 0.010 240)` | Inside the panel between sections. |
| Body text | `--text` | `oklch(0.94 0.006 240)` | Result text, captured selection (italic). |
| Soft text | `--text-soft` | `oklch(0.78 0.008 240)` | Menu items, default state. |
| Muted text | `--text-mute` | `oklch(0.58 0.008 240)` | Hints, metadata ("from Slack"). |
| Faint text | `--text-faint` | `oklch(0.44 0.008 240)` | Placeholder text. |
| Accent (active / streaming) | `--accent` | `oklch(0.74 0.10 255)` | Cohesive low-chroma blue (same family as the neutrals). Used **only** for focus indicator + streaming caret + result-toolbar action pill text. |
| Accent rail (focus 2px bar) | `--accent` | same | Left-edge of focused row. |
| Accent tint (focused row bg) | `--accent-tint` | `oklch(0.34 0.045 255 / 0.5)` | Subtle background tint of the focused row. |
| Quote rule (selection bar) | `--accent-mute` | `oklch(0.42 0.040 255 / 0.6)` | 2px vertical rule beside the captured selection text. |
| Error accent | `--accent-error` | `oklch(0.72 0.10 28)` | Low-chroma warm; used **only** in error states. Same shape as `--accent`. |
| Panel shadow | — | `0 14px 36px -8px rgba(0,0,0,0.55), 0 2px 6px rgba(0,0,0,0.4)` | Drop shadow under the panel for elevation. |

### 2.2 Light theme (inversion)

Same hues, lightness inverted. Worth specifying as a token map; the swiftui-expert pass commits values. Sketch-level targets:

| Role | Light theme target |
|---|---|
| Panel surface | `oklch(0.98 0.003 240)` |
| Panel surface 2 | `oklch(0.96 0.004 240)` |
| Panel border | `oklch(0.80 0.010 240)` |
| Hairline | `oklch(0.85 0.008 240)` |
| Body text | `oklch(0.20 0.008 240)` |
| Soft text | `oklch(0.34 0.008 240)` |
| Muted text | `oklch(0.42 0.010 240)` |
| Faint text (placeholders) | `oklch(0.52 0.010 240)` |
| Accent | `oklch(0.50 0.13 255)` (slightly darker for contrast against light background) |

Light mode follows from the inversion. If a color choice in dark conflicts with the light inversion (e.g., contrast falls below 4.5:1), dark's value wins and the light token rebalances individually.

> **Light-mode readability pass (2026-05).** The first light build was hard to read: the glass surface ran too translucent (50% tint over `.popover` vibrancy), so bright/busy desktop content bled through and wrecked text contrast — worst on the lighter grays. Two corrections: (1) light `panelTint` now runs nearly opaque (`oklch(0.98 0.003 240)` @ **0.90**) — a frosted-but-solid surface that prioritizes legibility over see-through glass; dark mode keeps its airier 0.42 tint. (2) The secondary grays and dividers were darkened for contrast on a light surface (muted `0.50→0.42`, faint `0.66→0.52`, soft `0.36→0.34`, hairline `0.92→0.85`, border `0.88→0.80`).

### 2.3 Typography

Native system stack — no custom font. Falls back through SF Pro on macOS.

```
--font: ui-sans-serif, -apple-system, BlinkMacSystemFont, "SF Pro Text",
         "Helvetica Neue", system-ui, sans-serif;
--font-mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
```

| Surface | Family | Size | Weight | Line height | Notes |
|---|---|---|---|---|---|
| Captured selection text | sans | 13px | 400 | 1.5 | Italic. Color `--text-soft`. |
| Selection metadata ("from Slack") | sans | 11px | 400 | 1.4 | Color `--text-mute`. Normal style. |
| Action menu row | sans | 13px | 400 default / 500 focused | 1.4 | Color `--text-soft` default; `--text` when focused. |
| Result text (streamed) | sans | 14px | 400 | 1.55 | Color `--text`. Slightly larger than selection — result is what the user reads. |
| Panel footer hints | sans | 11px | 400 | 1.45 | Color `--text-mute`. |
| Result-toolbar action pill | sans | 11px | 500 | 1.0 | Color `--accent`. Background `--accent-tint`. |
| Keyboard hint glyphs (`⌘↩`, `⌫`, `esc`) | mono | 11px | 500 | 1.0 | Color `--text-soft`. Always shown without surrounding bracket/box. |

**No display fonts. No custom display weights. No fluid typography.** Fixed sizes per the impeccable product register.

### 2.4 Spacing & layout rhythm

| Token | Value | Use |
|---|---|---|
| `--space-1` | 4px | Tightest. Inline kbd separators. |
| `--space-2` | 6px | Action row vertical padding. |
| `--space-3` | 8px | Footer padding-vertical. |
| `--space-4` | 10px | Filter input padding (Custom-mode only). |
| `--space-5` | 12px | Section internal gap, selection text gap. |
| `--space-6` | 14px | Footer padding-horizontal, result internal padding-vertical. |
| `--space-7` | 16px | Selection block padding, result horizontal padding. |
| `--space-8` | 20px | Reserved — not used in panel. |

Padding rhythm is **non-uniform on purpose** (per impeccable's "vary spacing for rhythm" law): selection block uses 16, action rows use 6 vertical / 10 horizontal, footer uses 8/14, result uses 14/16. The reader's eye traces these as distinct regions without needing strong dividers.

### 2.5 Radius & elevation

| Token | Value |
|---|---|
| `--radius` | 10px | Outer panel corners. |
| `--radius-sm` | 6px | Inner row backgrounds (focused row, result-pill). |
| Elevation 1 (panel) | drop shadow from §2.1 |
| Elevation 2 (none) | not used — panel is the only floating element |

No nested cards. No nested elevation. The panel is one elevated surface containing sections, not stacked panels.

### 2.6 Motion

All easing: `cubic-bezier(0.22, 1, 0.36, 1)` (ease-out-quart). No bounce, no spring, no overshoot. No CSS layout property animation (animate `opacity` + `transform` only).

| Moment | Property | Duration | Easing |
|---|---|---|---|
| Panel appear (from hotkey) | `opacity 0→1`, `transform translateY(8px → 0)` | 180ms | ease-out-quart |
| Panel dismiss | `opacity 1→0`, `transform translateY(0 → 4px)` | 120ms | ease-out-quart |
| Action focus move (between rows) | row `background-color` cross-fade | 100ms | linear |
| Action pick → result region | menu region `opacity 1→0` + result region `opacity 0→1` (no layout animation; result region was pre-rendered with `display: none` or equivalent — translate to SwiftUI as conditional view with `.opacity()` transition) | 200ms | ease-out-quart |
| Streaming caret | `opacity 1 ↔ 0.35` | 850ms cycle | ease-in-out (sinusoidal) |
| Accept → dismiss | brief accent flash on result text (`color` transition) → panel dismiss | 100ms flash + 120ms dismiss | linear → ease-out-quart |
| Error appear (toolbar swaps to error state) | `color` transition on toolbar text | 150ms | linear |

---

### 2.7 Component vocabulary

Surfaces in the notch are built by **composing a small set of named components**, not by re-applying tokens row-by-row. New features should reach for these first; tokens are an escape hatch for the rare case nothing fits. Each component already encodes its paddings, weights, hover treatment, and radii — that's the whole point.

Source: [`Localpen/DesignSystem/Components/`](./Localpen/DesignSystem/Components/).

| Component | What it is | Use it when… |
|---|---|---|
| **`SectionHeader(title:trailing:)`** | Small-caps 10pt semibold label, tracking 0.9, faint hue, padded to align with the row grid below. Optional inline `trailing` meta in subhead size (e.g. "editable", a count). | You're starting a labelled group of rows — "Recent", "Voice", "Facts", a future "Settings". **Not** for `ActionMenuView`'s headers, which are fixed-height for the sliding focus-highlight math. |
| **`MenuRow(icon:title:trailing:action:)`** | The canonical tappable row: SF Symbol leading at width 18, body title, optional `.text(String)` / `.chevron` trailing. Neutral hover lift (`rowHighlight`), inner-radius rounded fill. | Any list-of-things surface. Recents, the pinned profile row, future settings rows. Pick a `Trailing` variant; pass the closure. |
| **`BackBar(title:onBack:)`** | Small chevron-left + soft-toned label at the top of a detail surface. | Any pushed-from-list detail view: profile, future thread detail, future per-model settings. |
| **`Card { content }`** | A subtle inset surface: `chromeTint` fill, 0.75pt hairline stroke, `innerRadius`. Pads its own content. | Grouping an editable or read-mostly content block inside a section — e.g. the voice-card editor, a future "what the model sees" preview. |
| **`OutlineButton(title:role:action:)`** | Quiet pill button with hairline stroke and `rowHighlight` hover fill. `role: .normal` (soft text) or `.destructive` (`accentError` text). | Footer actions on detail surfaces — Regenerate, Forget everything, future Reset/Export. Pair two side-by-side; don't paint one as a primary fill (no glaring CTAs in this design). |
| **`EmptyStateView(icon:title:caption:)`** | Centered light-weight icon + menu-row title + soft subhead caption. | The "nothing yet" panel for any list surface. Same family as the recents empty state, so cold-start states across the app read as a coherent set. |

Plus the existing primitive **`Hairline()`** for 1px section dividers (lives in `Panel/PanelView.swift`).

**Rules:**
1. **Compose, don't re-style.** If you find yourself reaching for `RoundedRectangle(...)` + `Tokens.rowHighlight` + an `onHover` to build a row, you want `MenuRow`.
2. **One canonical version per pattern.** If a component's defaults don't fit, prefer adding a new variant (e.g. a new `Trailing` case) over per-feature tokens.
3. **Variants are explicit, not implicit.** A "destructive" button is `role: .destructive`, not "the same OutlineButton but the caller passed `Tokens.accentError`."
4. **ActionMenuView is the exception.** Its group headers and the sliding focus-highlight have positioning math coupled to fixed dimensions; those stay bespoke. Document that locally; don't reach for the menu's internals from elsewhere.

When a new pattern emerges that doesn't fit (third repetition, or it serves a meaningfully different role), extract a new component and add a row to this table.

**Ask chip rail** — small removable pills shown above `AskInput` representing
auto-attached context (app + window title, selection). Reuses `Tokens.rowHighlight`
fill and `Spacing.innerRadius`. No new design system pieces; lives in
`AskInput.swift` as a private `AskChip` view.

**Ask in the conversation surface** — the conversation/refinement surface is
shared with writing transforms, so ask-specific affordances are gated on
`Conversation.isAsk` (derived from the seed action, reliable on resume):

- *No refine chips.* "Soften / Tighten / More formal / More casual" are
  writing follow-ups; a Q&A answer has nothing to soften. Suppressed for ask.
- *Context block shows the attached selection, not the question.* For
  ask-with-selection the pinned block shows the text you attached (the real
  context); the question already reads as the seed user bubble. Ask-without-selection
  shows no block — there is no source.
- *Accept offers both Replace and Copy.* An answer is information you may want
  to keep, not a stamp over your selection. Ask-with-selection therefore offers
  BOTH (`AcceptAffordances.resolve`): Replace pastes back over the selection,
  Copy writes to the clipboard. Ask-without-selection and resumed asks are
  Copy-only (no live source field). Writing transforms keep their single
  Replace affordance.
- *Reply placeholder* reads "Ask a follow-up…" rather than "reply to keep
  refining…".

---

## 3. Panel anatomy & sizing

### 3.1 Window

- Type: `NSPanel` (translates from this spec; see swiftui-expert pass).
- Width: **360pt** fixed.
- Height: **content-fit**, with minimum 200pt and maximum 480pt. Result region scrolls if exceeded.
- Style mask: borderless, non-activating (key but doesn't steal focus from frontmost app for accessibility tree purposes; swiftui-expert specifies exact NSPanel flags).
- Background: `--panel-bg`, opaque. No vibrancy material in Phase 1 — vibrancy adds complexity and can clash with source-app accent colors. Reconsider in Phase 2.
- Corner radius: `--radius` (10pt). Applied to the window, not just an inner view.
- Shadow: per §2.5 elevation 1.

### 3.2 Anchoring

- **Position:** last-anchored, per source app's bundle ID. User drags the panel once for a given source app; that anchor is remembered.
- **Default for unseen state:** right edge of the current display, vertically centered, 24pt margin from edge.
- Phase 1 does NOT auto-position near the text caret. Too platform-fragile.
- Multi-display: anchor stored per display + source-app combination.

### 3.3 Vertical structure (Direction A — committed)

```
┌─────────────────────────────────┐  ← --radius outer corners, --panel-border
│ SELECTION BLOCK                 │  padding 16
│  ▎ "selection text"             │  italic --text-soft
│  ▎ from <SourceApp>             │  --text-mute, 11px
├─────────────────────────────────┤  --panel-hairline 1px
│ ACTION MENU (default)           │  padding 6 outer, rows 7×10
│   Proofread                     │
│ ▌ Polish     ← focused          │  --accent rail 2px left, --accent-tint bg, --radius-sm
│   More formal                   │
│   More casual                   │
│   Shorter                       │
│   Custom…                       │  --text-soft (trailing ellipsis indicates input opens)
├─────────────────────────────────┤  --panel-hairline 1px
│ PANEL FOOTER (hint strip)       │  padding 8/14, --panel-bg-2
│ ↑↓ select    ↩ apply · esc      │  --text-mute 11px
└─────────────────────────────────┘
```

When an action is picked, the **Action Menu** section transforms into the **Result** section (same vertical slot, animated per §2.6). The Selection Block stays unchanged.

### 3.4 Sub-elements

**Selection Block.**
- Two-column layout: 2px accent-mute rule on the left, text on the right. Gap 10pt.
- Selection text wraps. Maximum 4 visible lines; beyond, the text region becomes scrollable (overflow-y) with no visible scrollbar (native macOS overlay scroll).
- Below the text, a single-line metadata strip: "from " + source app name (resolved from bundle ID lookup). If app name unknown, "from another app."

**Action Row.**
- Height: 32pt (6pt vertical padding + 14.5pt line-height + 2pt visual buffer).
- Horizontal padding: 10pt for the row, 12pt for the inner content (so the focus rail can sit at the row's true left edge).
- Focused state: 2px accent rail on the left edge (full row height), `--accent-tint` background, label color shifts from `--text-soft` to `--text`, weight from 400 to 500.
- Hover (mouse) state: same background tint as focused but no rail. Subtle.
- Rows are **not separated** by hairlines — only the menu region as a whole is bordered top/bottom by hairlines.

**Result Section.**
- Padding: 14pt vertical, 16pt horizontal.
- Min height: 96pt (so the result region doesn't feel cramped on short outputs).
- Streaming caret: 7×16pt accent-colored block, vertical-align text-bottom, blinks per §2.6.
- Text is selectable. Click-and-drag = native macOS text selection.
- Text is editable inline — clicking enters edit mode (native NSTextView). Cursor blinks at insertion point (system caret, not the streaming caret).

**Result Toolbar (replaces panel footer when result is showing).**
- Padding: 8pt vertical, 14pt horizontal. Background `--panel-bg-2`. Top border `--panel-hairline`.
- Left: action pill — small pill labeled with the action name (e.g., "Polish"), text color `--accent`, background `--accent-tint`, padding 3pt vertical / 8pt horizontal, radius 999px.
- Right: hint cluster — "⌘↩ accept · ⌘C copy · esc back" (polish pass; was "⌫ try another"), key glyphs in the mono kbd style (`--text-soft`), labels `--text-mute`.

**Action Menu Grouping (Revise / Create).**
- The action menu is divided into two named groups: **Revise** (the five transforms: Proofread, Polish, More formal, More casual, Shorter, plus Custom) and **Create** (Respond). Each group is preceded by a short section header label rendered in `--text-mute` at 11px, uppercase, non-interactive.
- Keyboard navigation remains a single flat list — `↑↓` moves through all rows in document order across both groups, wrapping top/bottom. No submenus.
- **Respond** is set apart with a **monochrome lift**, not a hue: its row label sits at full `--text` even at rest (instead of `--text-soft`), reading as quietly more prominent than the transforms above it. This preserves the single-accent discipline (the only color note stays the blue focus rail + caret). The CREATE group header carries the rest of the distinction. The focused state is identical to every other row (`--accent-tint` background + `--accent` rail). *(Superseded the earlier green "create" tint, which introduced a second accent hue and read as off-palette.)*
- The Respond row is **disabled** when no selection was captured (S3 empty state): rendered at reduced opacity (`--text-faint`) and skipped by keyboard focus.
- **Create results copy to the clipboard and do not paste back.** When the user accepts a Respond result (`⌘↩`), the result is placed on the clipboard and the panel dismisses — identical to `⌘C` on a Revise result. The result-toolbar footer hint updates to reflect this: "**⌘↩ copy reply** · esc back". The action pill in the toolbar reads "Respond."
- Revise results continue to paste back as before.

### 3.5 Custom prompt mode

When the user picks **Custom…** or **Respond** from the action menu, the menu region (not the selection block) transforms into a compose field:

```
├─────────────────────────────────┤
│ ▏ How should I reply?  (optional)│  rail field (§3.6) + placeholder --text-faint
├─────────────────────────────────┤
│ ↩ submit · ⇧↩ newline · esc back │  same footer slot
└─────────────────────────────────┘
```

- Self-sizing field (native NSTextView); grows with its content, no scrollbar until tall.
- ↩ Return submits (⇧Return inserts a newline). Esc returns to the action menu.
- Custom requires non-empty input; **Respond** accepts empty (empty = a sensible default reply).

On submit, the compose region becomes the Result section (same animation as picking a fixed action).

### 3.6 Input fields — the rail treatment

Both editable inputs (the **type/paste** field in S2/S3 and the **Custom/Respond** compose field) share one borderless treatment, so they read as one system with the action menu rather than as web-style form boxes:

- **No box, no fill, no border ring.** The field is bare text on the panel surface.
- **A left rail** is the only structure: a 1px `--panel-hairline` at rest, animating to the 2px `--accent` rail on focus — the *same* focus indicator the action menu uses for the focused row. Quick ease-out (~150ms).
- Placeholder is `--text-faint`, **regular weight (not italic)**. Text sits inset (`--space-5`) to clear the rail.
- This supersedes the earlier filled-box input and the `›` prompt-glyph sketch: the single accent note stays the focus rail + caret, never a full bordered ring.

---

## 4. State catalog

Seven primary states. Each has a precise visual definition; transitions per §2.6.

### S1 — First-run permission ask

Shown the first time the app launches, before any model download. Standalone window (NOT the floating panel — this is a one-time onboarding window, ~480pt wide × ~280pt tall, centered).

| Element | Content |
|---|---|
| Headline (`--text`, 17pt, weight 600) | Localpen needs Accessibility permission |
| Body (`--text-soft`, 13pt) | Localpen reads selected text and pastes results back into the app you're writing in. macOS will ask for Accessibility permission next. Your text never leaves this Mac. |
| Primary button | "Open System Settings" (filled, `--accent` background, white text) |
| Secondary link | "Why does Localpen need this?" → expands a small disclosure paragraph explaining the AX-permission scope (no tree-walking, only synthetic ⌘C/⌘V per [ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md)) |
| Footer (subtle) | Localpen is open source · localpen.app (or whatever domain ends up locked) |

No "Skip" button. The app is non-functional without the permission.

After the user grants permission (returned focus from System Settings), this window transitions to **S2**.

### S2 — Model downloading

Shown after S1, before first usable session.

| Element | Content |
|---|---|
| Headline | Downloading Qwen 2.5 7B Instruct |
| Subhead (`--text-mute`, 11px) | This happens once. Your model lives on your Mac after this. |
| Progress bar | Linear, 100% width, height 4pt, radius 2pt. Background `--panel-bg-2`, fill `--accent`. |
| Progress text (`--text-soft`, 13px, mono digits) | "1.2 GB of 4.4 GB · ~3 min remaining" |
| History disclosure (`--text-mute`, 11px) (from ADR 0006) | "Localpen saves your interactions locally so it can learn your style over time. Your data never leaves this Mac. [Manage history…]" |
| Tertiary disclosure | "Use a different model" → opens the model registry list (Power User affordance from [ADR 0005](./docs/adr/0005-model-agnostic-architecture.md)). Closes back to this screen when picked. |
| Cancel | Available — cancels download and returns to S1 prompt to try another model |

When download completes, this window fades and the **floating panel** becomes summonable. No success modal — the user discovers the panel works by pressing the hotkey.

### S3 — Empty / no selection

User pressed the hotkey but synthetic ⌘C produced no clipboard change (no text selected, or app blocked the copy). Panel appears as normal.

```
┌─────────────────────────────────┐
│ EMPTY                           │
│  No text selected.              │
│  Type a prompt to use Localpen. │
├─────────────────────────────────┤
│ ▸ ▌                             │  empty Custom textarea — full width
│   Type a custom prompt…         │
├─────────────────────────────────┤
│ ↩ submit · esc dismiss          │
└─────────────────────────────────┘
```

The selection block is replaced by a 2-line message (italic on first line, `--text-soft`; second line `--text-mute`). The action menu is replaced by the same Custom textarea from §3.5.

On submit, behaves like a Custom-prompt result.

### S4 — Captured / action menu visible

The canonical state. Panel structure per §3.3.

Initial focus: **Polish** (the most common action, per the v1 action set thinking in [ADR 0004](./docs/adr/0004-v1-action-set.md)). User can change with ↑↓ or click.

### S5 — Generating / streaming

Same panel, action menu region replaced by Result section. Result-toolbar replaces panel footer.

The streaming caret blinks per §2.6. Tokens append. No scrollbar; the result region grows up to max-height, then scrolls (overflow-y, native macOS overlay scrollbar).

The action pill in the toolbar identifies which action is running. If the user re-runs (⌫), the pill briefly fades, the menu region restores, and the result is cleared.

### S6 — Result / accept

Streaming complete. Caret stops blinking and disappears. Result text becomes editable on click. Toolbar continues to show ⌘↩ accept and ⌫ try another.

If the user clicks into the result to edit, the toolbar updates to show "↩ submit edit · esc cancel edit" instead. After Esc or click outside, returns to the standard toolbar.

### S7 — Error states (family)

All errors share one visual template: the result region (or, where there's no result, the action menu region) is replaced by a single-line error message in `--accent-error`, with an action button on the right.

Specific errors:

| Trigger | Message | Action |
|---|---|---|
| Local model server stopped responding | "Model server stopped. Restarting…" | [Retry] — re-spawns llama-server and resumes |
| Generation timeout (>30s no token) | "Taking longer than usual." | [Cancel] [Wait] |
| Synthetic ⌘V failed to paste (per ADR 0003 paste-back failure) | "Result copied. Press ⌘V in your app." | [Dismiss] |
| Disk full during model download | "Not enough space — need ~4 GB free." | [Open Storage Settings] |
| Hotkey conflict with another app | "Couldn't capture the hotkey. Change in Localpen settings." | [Open Settings] |
| Network error during model download | "Can't reach the model server. Check your connection." | [Retry] |

All error text fits on one line at panel width when possible; wraps to two lines otherwise. The error color `--accent-error` is used only here — not anywhere else in the UI.

---

## 5. Interaction model

### 5.1 Keyboard contract

| Key | State | Action |
|---|---|---|
| Global hotkey (default `⌃⌥Space` — see §5.4) | (any) | Open panel with captured selection, focus action menu |
| `↑` `↓` | S4 (action menu) | Move focus through action list (wraps top/bottom) |
| `↩` Return | S4 | Pick focused action → S5 |
| Any letter | S4 | Reserved for later; in Phase 1, **non-filter** (typing doesn't filter — arrow keys are faster for 6 items). The exception: typing while Custom is focused selects it AND opens the Custom textarea. |
| `↩` Return | S5 streaming | (no-op — let it stream) |
| `⌘↩` | S5/S6 | Accept result → paste-back → dismiss |
| `↩` Return | S6 | Same as `⌘↩` (accept) |
| `⌘C` | S6 | Copy result to clipboard (no paste-back) |
| `⇥` Tab | S4/S6 | Cycle focus: input ↔ menu; from result, enter edit mode |
| `Esc` | S6 | Return to action menu (keeps selection); `Esc` again dismisses |
| `Esc` | (other) | Dismiss panel without paste-back |
| `↩` Return | Custom-mode input | Submit prompt (Shift+Return = newline) |
| `⌫` on empty Custom input | Custom-mode | Return to action menu |

### 5.2 Mouse / trackpad

- Action rows clickable.
- Result text selectable and editable on click.
- Panel draggable from any non-interactive region (the selection block top is the obvious grab handle).
- Click outside panel → dismiss.
- Right-click anywhere on the panel → context menu: Copy Result · Open History · Change Model · Settings… · About Localpen.

### 5.3 Focus management

- Panel is non-activating — opens without stealing focus from the source app (so the source app retains its text cursor / selection state, important for paste-back).
- An invisible focus proxy receives keyboard events while the panel is up; on dismiss, focus returns naturally to the source app.

### 5.4 Hotkey default

**Default global hotkey: `⌃⌥Space` (Control + Option + Space).**

Reasoning:
- `⌘⇧Space` collides with macOS Spotlight (taken).
- `⌃Space` collides with macOS Input Source switcher in some configs.
- `⌥Space` and `⌥⌘Space` are sometimes claimed by clipboard managers.
- `⌃⌥Space` is rarely claimed and easy to chord.

User can change the hotkey via Settings (Phase 1 ships a Settings window with one row: "Hotkey: [chord recorder]"). Conflict detection: if the recorded hotkey is claimed by another app, the recorder shows "Already used by <App>" and rejects the binding.

### 5.5 Dismiss model

The panel dismisses on:
1. Esc keypress (any state)
2. Click outside the panel
3. After successful paste-back (S6 accept)

The panel does NOT dismiss on:
- Hotkey re-press while open — that's a no-op (avoid accidental dismiss)
- App switch via ⌘Tab — the panel persists but loses focus; the user can switch back

---

## 6. Microcopy catalog

Final committed copy for all surfaces. Voice: terse, native, slightly understated. Sentences end with periods. No exclamation marks. No emoji in chrome.

| Surface | Text |
|---|---|
| Selection metadata | from <App Name> |
| Selection metadata (unknown app) | from another app |
| Action group headers | Revise · Create |
| Action labels | Proofread · Polish · More formal · More casual · Shorter · Custom… · Respond |
| Result toolbar hints (Create action) | ⌘↩ copy reply · esc back |
| Action menu footer | ↑↓ select · ↩ apply · ⇥ edit · esc close |
| Result toolbar hints | ⌘↩ accept · ⌘C copy · esc back |
| Result toolbar (editing) | ↩ save · esc cancel |
| Empty state line 1 | No text selected. |
| Empty state line 2 | Type a prompt to use Localpen. |
| Custom textarea placeholder | Type a custom prompt… |
| Custom textarea footer | ↩ submit · ⌫ back to menu · esc dismiss |
| First-run headline | Localpen needs Accessibility permission |
| First-run body | Localpen reads selected text and pastes results back into the app you're writing in. macOS will ask for Accessibility permission next. Your text never leaves this Mac. |
| First-run button | Open System Settings |
| First-run "why" expand | Localpen uses Accessibility permission to read your text selections (via the clipboard) and paste results back. It never walks the accessibility tree, never sends anything over the network. Permission can be revoked any time in System Settings. |
| Model download headline | Downloading Qwen 2.5 7B Instruct |
| Model download subhead | This happens once. Your model lives on your Mac after this. |
| Model download progress | <X> GB of <Y> GB · ~<N> min remaining |
| History disclosure | Localpen saves your interactions locally so it can learn your style over time. Your data never leaves this Mac. |
| History disclosure link | Manage history… |
| Model picker link | Use a different model |
| Error: model server | Model server stopped. Restarting… |
| Error: timeout | Taking longer than usual. |
| Error: paste-back failed | Result copied. Press ⌘V in your app. |
| Error: disk full | Not enough space — need ~4 GB free. |
| Error: hotkey conflict | Couldn't capture the hotkey. Change in Localpen settings. |
| Error: network | Can't reach the model server. Check your connection. |

---

## 7. What this design deliberately does NOT include

Worth naming to keep swiftui-expert (and future-you) from drifting:

- ~~**No vibrancy material on the panel.**~~ **Superseded by the 2026-05 polish pass** — the panel now uses `NSVisualEffectView` vibrancy (`.hudWindow` dark / `.popover` light) over a tint, with a Reduce Transparency solid fallback. See the polish-pass note at the top.
- **No per-action keyboard shortcuts in the menu (`⌘P`, `⌘L`, etc.).** Considered, dropped — arrow keys + Return are faster for 6 items, and visible shortcuts add visual noise to the menu row.
- **No type-to-filter on the action menu.** 6 items doesn't need filtering. The Custom textarea is opened by picking Custom — explicit.
- **No proactive nudges.** "This email reads tense — soften?" is a Phase 1.5 capability that requires passive text observation. Not in Phase 1.
- **No message history visible.** Past interactions are persisted ([ADR 0006](./docs/adr/0006-persist-interactions-from-day-1.md)) but not surfaced in the panel. Phase 1.5 adds a thread view; Phase 2 surfaces inferred-style hints.
- **No model selector UI in steady state.** "Change model" lives behind a secondary disclosure on the model-download screen and (eventually) in Settings. Not in the main panel chrome.
- **No animated app-launch sequence.** Per the impeccable product register — "users don't want to watch it load."
- **No tooltips on action labels.** Labels are precise enough; tooltip is noise.
- **No light / dark theme toggle in the panel.** Follow macOS system appearance via `NSAppearance`.

---

## 8. Open implementation questions for swiftui-expert

(Not design questions — engineering ones the design doesn't constrain.)

1. NSPanel exact style mask combination (`.nonactivatingPanel`, `.borderless`, `.titled` off, etc.) — pick the combination that gives a borderless rounded-corner floating window that doesn't steal focus.
2. How to implement the per-source-app last-anchored position (per-bundle-ID anchor store; UserDefaults? a small SQLite next to interactions.sqlite?).
3. Streaming pipe: how the llama-server SSE / chunked response drives the result TextView. SwiftUI Text vs NSTextView for editability + streaming + selection.
4. How to detect "synthetic ⌘V didn't paste" reliably enough to switch to the clipboard-fallback error per ADR 0003 (S7 row 3).
5. Hotkey chord recorder UI for Settings — `KeyboardShortcuts.Recorder` (SwiftUI-native) handles capture; visual design follows the same Restrained palette. See [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md).
6. How "selection scrolls past 4 lines" interacts with NSPanel sizing — does the panel grow, or does the selection region scroll within a fixed panel height? (Design recommendation: selection scrolls within fixed panel height of 480pt max.)

---

## 9. Pass 2 / future revisions

This DESIGN.md is locked for swiftui-expert handoff. Future revisions explicitly out of scope here:

- **Vibrancy material trial** (Phase 2): re-test `.hudWindow` material on the panel surface; may improve "feels native" further.
- **Light theme refinement** (Phase 1 ship): once dark looks right in actual SwiftUI build, do a focused light-mode pass against the inverted token map.
- **Phase 1.5 chat thread design**: now specified in [DESIGN-1.5.md](./DESIGN-1.5.md) (conversational surface, built + merged 2026-05-27).
- **Settings window design**: deliberately not specified in v1 — a single-row settings window (Hotkey + model picker entry) is the Phase 1 placeholder. Worth a quick second sketch pass when the build is close to that screen.
