# Localpen Phase 1 — Design Brief (sketch / mid-fi)

> Directional exploration. Multiple options where the right answer isn't obvious yet. A second impeccable pass produces the production-ready DESIGN.md once direction is committed.

See: [PRD.md](./PRD.md), [CONTEXT.md](./CONTEXT.md), [docs/adr/](./docs/adr/).

---

## 1. Feature summary

The Phase 1 floating panel — Localpen's single visual surface. Summoned by global hotkey while text is selected in any source app. Hosts the entire quick-action experience end to end: shows the captured selection, presents the 6-item action menu, streams the model result, accepts back into the source app, dismisses.

Phase 1.5 extends this same `NSPanel` into a persistent conversational surface. Phase 1's design must accommodate that growth without redesign — the structure has to support multi-turn history later without becoming awkward today.

---

## 2. Primary user action

> Press hotkey on selected text → see selection captured in the panel → pick an action → watch result stream → accept → return to source app silently.

Everything else (first-run, errors, model download) is plumbing the user passes through once. The above is the daily loop and the polish gate.

---

## 3. Design direction

### Color strategy: Restrained

Tinted near-blacks (oklch lightness ~0.18, chroma ~0.01, hue ~250° — a faint cool tint, not blue-blue) + a single subtle accent for active state and the streaming cursor. The panel coexists quietly with any source app — Slack purple, Cursor magenta, Mail blue — without color-clashing.

The accent: probably a desaturated teal (`oklch(0.78 0.08 200)`) or a warm gold (`oklch(0.82 0.08 80)`). Both directions are tested in the production-ready pass; sketch-level we just note "single, low-chroma, used for active state + streaming caret only."

No gradients. No glass. No tinted shadows of the accent color (a real temptation — resist).

### Theme: Dark-first

Scene sentence:

> A developer at 11pm in dark-mode Slack pauses mid-message, hits the hotkey, the panel appears in their peripheral vision, stays quiet against the dark workspace, streams a polished sentence in 400ms, gets dismissed without breaking flow.

Both themes ship via macOS `NSAppearance`. Dark carries the design vision; light is the inversion. Dark mode is where Localpen looks like *itself*.

### Anchor references

| Anchor | What we take | What we don't |
|---|---|---|
| **Granola** | The "small floating contextual window" form factor. Anchored, persistent-during-use, calm. Acknowledged in PRD as the spiritual sibling. | Granola is task-context-driven (meeting notes); we're invocation-driven (hotkey). Don't borrow its always-on presence. |
| **Raycast** | The latency aesthetic: instant appear, keyboard-first, type-to-filter, single ⌘+key shortcuts. The command-bar mental model for the action list. | Raycast is a launcher; it consumes screen space generously. Localpen is anchored next to your writing — must be tighter, narrower. |
| **Things 3** | Native-macOS polish: ease-out motion at 200ms, generous breathing room, thoughtful typography, restraint with color. Sets the "feels native" floor. | Things is a productivity app with persistent surface; Localpen is transient. Don't borrow Things' rich-content layouts. |

### Anti-references (worth naming so swiftui-expert doesn't drift toward them)

- Apple Writing Tools' result balloon. It feels like a system tooltip, not a tool. Localpen is a tool.
- ChatGPT Mac app. Too chrome-heavy; too "AI app."
- Electron command-bars (Slack quick-switcher, VS Code command palette). Right interaction model, wrong typographic fidelity.

---

## 4. Scope

| Axis | Sketch/mid-fi answer |
|---|---|
| Fidelity | Sketch with ASCII anatomy + descriptive intent. Color/type tokens proposed in ranges, not fixed values. |
| Breadth | The panel + 7 key states + first-run flow (sketched, not fully spec'd). Phase 1.5 conversation hinted, not designed. |
| Interactivity | Static spec; motion described in words. |
| Time intent | Directional commit. Production-ready spec is pass 2. |

---

## 5. Layout strategy — three directional options

The fundamental question: **how is information organized in the panel?** I'm presenting three sketches with trade-offs rather than picking one. Comment on which feels right and the production-ready pass commits.

### Direction A — Stacked: selection / menu / result

```
┌─────────────────────────────────────┐
│  ▎ "hey can u send me the doc when  │
│  ▎  you get a sec"                  │ ← captured selection
│  ▎ from Slack                       │
├─────────────────────────────────────┤
│   Proofread                         │
│ → Polish                            │ ← keyboard focus
│   More formal                       │
│   More casual                       │
│   Shorter                           │
│   Custom…                           │ ← typed prompt mode
└─────────────────────────────────────┘
                              ⌘↩ apply
```

On action pick, the menu region transforms into the streaming result:

```
┌─────────────────────────────────────┐
│  ▎ "hey can u send me the doc when  │
│  ▎  you get a sec"                  │
│  ▎ from Slack                       │
├─────────────────────────────────────┤
│  Hi — could you send the doc        │
│  when you have a moment?▌           │ ← streaming
│                                     │
│                                     │
│                                     │
└─────────────────────────────────────┘
       Polish  ↩ accept   ⌫ try another action
```

- **Pros:** clearest mental model — selection on top, action below, result replaces action. Naturally extends to Phase 1.5 (the bottom region becomes a chat thread; the selection becomes the conversation context).
- **Cons:** more vertical real estate. Anchored panel is taller. Some screen-edge anchoring becomes awkward.

### Direction B — Command-bar: selection above, filterable list below

```
┌───────────────────────────────────┐
│ ⌘ Localpen        "hey can u sen…"│ ← selection truncated, hover for full
├───────────────────────────────────┤
│  ▸                                │ ← type here to filter or write Custom
├───────────────────────────────────┤
│   Proofread        ⌘P             │
│ → Polish           ⌘L             │ ← keyboard focus, accent bar
│   More formal      ⌘F             │
│   More casual      ⌘K             │
│   Shorter          ⌘S             │
│   Custom prompt…                  │
└───────────────────────────────────┘
```

- **Pros:** Raycast-native. Type to filter actions; "p" focuses Polish, "f" focuses More formal. Power users learn ⌘P / ⌘L / ⌘F shortcuts. Tightest UX for the hotkey-then-keyboard flow.
- **Cons:** the selection is truncated to one line — for selections of >1 sentence, the user can't verify what was captured. Mitigatable with hover-expand, but adds complexity.
- **Phase 1.5 path:** chat thread replaces the action list region.

### Direction C — Hybrid: selection visible always, menu filterable

```
┌─────────────────────────────────────┐
│  ▎ "hey can u send me the doc       │
│  ▎  when you get a sec"             │ ← always visible (up to ~4 lines, scroll past)
├─────────────────────────────────────┤
│  pol▌                               │ ← user typed "pol"
├─────────────────────────────────────┤
│ → Polish                            │ ← filtered, autoselected
│   Proofread                         │
└─────────────────────────────────────┘
```

- **Pros:** keeps selection visible (Direction A's strength) AND keyboard-filterable (Direction B's strength). Best of both.
- **Cons:** more code to build (filter logic + always-visible selection panel). Slightly taller than B.
- **Phase 1.5 path:** the selection block becomes the active conversation context; the filterable list becomes a hybrid command/chat input.

### Recommendation

**Direction C** if implementation cost is acceptable — it preserves the two affordances that matter most (see-your-selection + type-to-filter) without the trade-off of A or B. **Direction A** if you want the cheapest path to Phase 1.5 (the chat extension is most obvious in A). **Direction B** is the worst fit because truncating the selection breaks trust on selections longer than one sentence.

---

## 6. Key states

Sketch-level: brief intent + key affordance for each. Production-ready pass nails layout and motion.

### S1. First-run permission ask

User has just opened the .dmg and launched Localpen. macOS will surface the Accessibility permission prompt. We need a non-blocking explanatory pre-prompt so the user knows what's about to be asked.

> One screen. Headline: "Localpen needs to read selected text and paste results."
> Subhead: "macOS will ask for Accessibility permission. Click 'Open System Settings' — we'll wait."
> Primary action: "Open System Settings". Subtle "Why?" link expands a paragraph about the permission scope. **No** "skip" button — the app is non-functional without it.

### S2. Model downloading

First launch, post-permission. ~4.4 GB download. Several minutes on broadband.

> One screen. Headline names the model ("Downloading Qwen 2.5 7B Instruct…"). Below: progress bar with bytes/total + estimated time. "Cancel" allowed. "Change model" affordance behind a small disclosure (links to the model registry from ADR 0005). Nothing else — this is a wait screen, not a place to explore.

### S3. Empty / no selection

User hit hotkey but the pasteboard came back unchanged (no text selected, or app blocked the synthetic ⌘C).

> The panel still appears — the hotkey shouldn't feel broken. Headline area says "No text selected — type a prompt instead." The input box accepts a free-form prompt. Picking "Custom" is implicit; the action list is hidden. Esc to dismiss.

### S4. Captured (selection visible, action menu visible)

The daily case. Selection text visible at top. Menu below. Keyboard focus on Polish (the most common action; arrow keys move; typing filters in Direction B/C).

### S5. Generating (streaming)

User picked an action. The menu region transforms into a streaming result area. Tokens appear progressively. A subtle accent caret blinks at the streaming edge. **No spinner.** Streaming itself is the loading affordance.

The originating action is labeled below the result ("Polish") so the user can re-trigger if they want a different action without re-capturing. **A subtle re-roll affordance** ("⌫ try another action" or similar) re-presents the action menu with the selection still captured.

### S6. Result / accept

Stream finished. The result is editable inline (user can correct one word before accepting). Primary action: ⌘↩ Accept (silent paste-back, panel dismisses). Secondary: ⌫ re-pick action. Tertiary: Esc dismiss without paste-back.

### S7. Error states (sketched as a family, not individually)

- Model server not running / crashed → "Model server stopped. Restarting… [Retry]"
- Generation hangs > 30s → "Taking longer than usual. [Cancel] [Wait]"
- Paste-back failed (synthetic ⌘V didn't land) → "Result copied to your clipboard. Press ⌘V in your app." (graceful fallback to user-driven paste)
- Disk-full during model download → standard macOS-friendly error with action

All errors share one visual template — single line, accent color tinted toward red but kept low-chroma, action button on the right.

---

## 7. Interaction model

### Keyboard-first contract

| Input | Effect |
|---|---|
| Global hotkey (default: `⌘⇧L` — see open question) | Open panel with captured selection |
| `↑` `↓` | Move keyboard focus through action list |
| Type a letter / word | (Direction B/C) Filter actions live; if input is unambiguous Custom prompt territory, switch to free-form mode |
| `↩` Return | Pick focused action, start streaming |
| `⌘↩` | Accept result, silent paste-back, dismiss |
| `⌫` (after pick) | Re-present action menu, selection still captured |
| `Esc` | Dismiss without paste-back |
| Click outside panel | Dismiss without paste-back |

### Mouse-second

Action items clickable; result-area editable on click; Accept button visible at result stage for non-keyboard users. Hover states are subtle — no lift, no shadow puff, just a faint accent-tint on the row background.

### Anchoring

Panel position: **last-anchored**. User drags it once; it remembers per-display per-source-app (so it floats in a different spot when writing in Slack vs Mail). Default for unseen state: right edge of the current display, vertically centered, ~24pt margin from edge.

Phase 1 does NOT auto-position next to the selection cursor — too jumpy, too platform-fragile, and the value isn't proven. Save for Phase 2+ experimentation.

### Motion

| Moment | Behavior | Duration | Curve |
|---|---|---|---|
| Panel appear | Fade-in + 8pt upward slide | 180ms | ease-out-quart |
| Panel dismiss | Fade-out + 4pt downward slide | 120ms | ease-out-quart |
| Action focus move | Background-color cross-fade on rows | 100ms | linear |
| Action pick → streaming | Menu region collapses, result region expands | 200ms | ease-out-quart |
| Streaming caret blink | Opacity 1.0 ↔ 0.4 | 800ms cycle | sinusoidal |
| Result accept → dismiss | Brief accent-color flash on result text + panel dismiss | 100ms flash + 120ms dismiss | linear / ease-out |

No bounce. No spring. No layout-property animation (animate opacity + transform only).

---

## 8. Content requirements

Voice: terse, native, slightly understated. No exclamation marks. No emoji in chrome (emoji in user content is fine). No "Click here to…" patterns. The interface speaks like a calm operator, not a cheerful product.

### Action labels (final, per ADR 0004)

- Proofread
- Polish
- More formal
- More casual
- Shorter
- Custom…

(Trailing ellipsis on Custom indicates it opens a prompt input — established macOS convention.)

### Microcopy drafts

| Surface | Draft |
|---|---|
| First-run permission pre-prompt | "Localpen needs to read selected text and paste results. macOS will ask for Accessibility permission next." |
| Model download in progress | "Downloading Qwen 2.5 7B Instruct — 1.2 GB of 4.4 GB" |
| Model download done | (no notification; panel becomes usable; user discovers via next hotkey) |
| Empty state in panel | "No text selected. Type a prompt to use Localpen." |
| Action stage focus indicator | (no text; visual focus ring only) |
| Streaming caret | (no text) |
| Result accept hint | "⌘↩ accept" (subtle, bottom-right of result area) |
| Try-another-action hint | "⌫ try another" (subtle, paired with the action label below result) |
| Server-not-running error | "Model server stopped. Restarting… [Retry]" |
| Paste-back failed | "Result copied — press ⌘V in your app." |

### History disclosure (per ADR 0006)

Surfaced inline on the first ever post-permission first-run screen, below the model-download progress bar, in a smaller secondary type weight:

> "Localpen saves your interactions locally so it can learn your style over time. Your data never leaves this Mac. [Manage history…]"

The "Manage history…" link is a placeholder for Phase 1's Power-User "clear/export history" affordance.

---

## 9. Recommended reference reads for the production-ready pass

Pull these from `/Users/charliexue/.claude/skills/impeccable/reference/` when committing the direction:

- `spatial-design.md` — NSPanel sizing, anchoring, padding rhythm
- `motion-design.md` — appear/dismiss curves, streaming behavior
- `typography.md` — selection-display vs result-text vs menu typography
- `color-and-contrast.md` — Restrained palette tokens, accent ranges
- `interaction-design.md` — keyboard model, filter mechanics
- `ux-writing.md` — error states, copy edges

---

## 10. Open questions for the production-ready pass

1. **Direction A / B / C** — which layout commits.
2. **Hotkey default.** `⌘⇧Space` collides with Spotlight; `⌘⇧L` is free but mnemonically weak. `⌃⌥Space`? `Hyper+L`? Phase-1 ship needs a recommended-default and a "change shortcut" affordance.
3. **Custom prompt UX mechanics.** Type-into-the-filter-and-it-becomes-Custom (Raycast pattern) OR Custom is a separate explicit picker that opens a textarea? Direction depends on layout choice.
4. **Accent color exact value.** Desaturated teal vs warm gold. Try both in the next pass; pick the one that doesn't trigger category-reflex against any specific source-app brand color.
5. **Selection display max height.** Tall selections (multi-paragraph) — truncate, scroll-within-region, or expand-the-panel? Direction A makes this most natural; B forces a decision.
6. **Result-stage editability granularity.** Inline-edit-and-accept, or accept-and-edit-in-source-app? Affects how much editing UI lives in the result region.
7. **Where the "change model" affordance lives** in steady-state (not first-run). Probably a small `⋯` menu in the panel chrome, hidden behind a hover. Worth nailing in pass 2.
8. **What the panel chrome looks like.** Borderless? 1px hairline? Subtle shadow? Vibrancy material (`.hudWindow`)? Defer to spatial-design.md + actually building it on hardware.

---

## What to react to before committing

The four highest-leverage choices are:

1. **Layout direction** (A vs B vs C) — affects everything else.
2. **Anchoring** (last-anchored, my recommendation) — affects user expectations and code.
3. **Custom-prompt UX** (type-to-Custom vs explicit picker) — affects keyboard mental model.
4. **Hotkey default** — annoying to change post-launch.

Resolve these four and the second impeccable pass produces a tight, committed DESIGN.md.
