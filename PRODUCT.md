# Localpen — PRODUCT

> impeccable context file. Defines users, brand, tone, anti-references, and strategic principles. impeccable's `load-context.mjs` reads this on every design invocation. The PRD-shaped subset that impeccable cares about.

---

## register

`product` — Localpen's surfaces are app UI where the user is in a task (capture text → pick action → see result). Not marketing or brand surfaces. Treat all design work as product-register unless explicitly noted otherwise.

---

## Users (phased)

- **Phase 0–1:** technical early adopters. r/LocalLLaMA, Hacker News, GitHub-OSS crowd. Actively shopping for an Ollama alternative. They expect to see model choice, quant selection, system prompts — power-user defaults are fine.
- **Phase 2:** writers, researchers, knowledge workers. The Mac-centric Setapp / Bear / Notion audience.
- **Phase 3:** non-technical users. "ChatGPT-quality help without trusting the cloud." Apple Writing Tools confirms this category is real. "Invisible default" becomes load-bearing here.

Phase 1 design choices target **Phase 0–1**.

---

## Product purpose

A native macOS writing companion. Local AI. Watches what you've selected via clipboard-mediated capture, transforms it via a precise action (Proofread / Polish / More formal / More casual / Shorter / Custom), pastes the result back into the source app.

**Thesis:** people keep ChatGPT open in a tab and shuttle text back and forth all day. Localpen ends the shuttle.

See [PRD.md](./PRD.md) for the full product vision; this file is the impeccable-shaped subset.

---

## Brand voice & tone

Terse, native, slightly understated. The interface speaks like a calm operator, not a cheerful product.

- No exclamation marks.
- No emoji in chrome (emoji in user content is fine).
- No "Click here to…" patterns.
- Action labels are direct verbs/adjectives ("Polish", "More formal"), not full sentences.
- Microcopy stays in the user's mental model — they're writing, not configuring.
- Errors describe what happened and offer one next action. Never apologize.

See [DESIGN.md §6](./DESIGN.md) for the full microcopy catalog.

---

## Strategic principles

1. **Interface quality is the gate.** The product lives or dies on how the panel feels. Polish > features.
2. **Power users get the full surface in Phase 1.** Don't hide what they came for. The "invisible default" pitch is a Phase 3 promise, not v1.
3. **Open source, OSI-licensed from day one.** No "All rights reserved" mess.
4. **Local-first, no cloud option.** Adding a cloud fallback would dilute the central promise.

---

## Anchor references — what we riff on

- **Granola** — small floating contextual panel; sibling product. Take: anchored, present-but-not-intrusive form factor. Skip: always-on presence (Localpen is invocation-driven, not task-driven).
- **Raycast** — command-bar precision, fast appear/dismiss, keyboard-first. Take: the latency-aesthetic standard. Skip: screen-space consumption (Localpen must be tighter).
- **Things 3** — extreme native-macOS polish, ease-out motion, generous breathing room. Take: the "feels native" floor.

## Anti-references — design must NOT drift toward these

- **Apple Writing Tools' result balloon.** Feels like a system tooltip, not a tool. Localpen is a tool.
- **ChatGPT Mac chrome.** Too heavy, too "AI app."
- **Electron command-bars** (Slack quick-switcher, VS Code command palette). Right interaction model, wrong typographic fidelity.

---

## Theme & color stance

- **Color strategy: Restrained.** Tinted neutrals + a single low-chroma accent ≤10%. The panel must coexist with any source app's chrome without color-clashing.
- **Theme: Dark-first.** Both themes ship via `NSAppearance`. Dark carries the design vision.
- **Accent:** desaturated teal (`oklch(0.78 0.085 200)`), used only for active focus + streaming caret + result-toolbar pill. Never decorative.

Full token palette in [DESIGN.md §2](./DESIGN.md).

---

## Canonical vocabulary (surfaces)

Localpen has two **surfaces** that share a single NSPanel, shipped in stages:

1. **Quick-action surface (Phase 1):** transient. Hotkey → menu → action → result → paste-back → dismiss. Latency target <500ms hotkey-to-first-token belongs to this surface.
2. **Conversational surface (Phase 1.5):** persistent. Same panel becomes multi-turn chat.

The word "surface" is canonical — not "mode", not "view", not "screen". See [CONTEXT.md](./CONTEXT.md) for the full glossary.

---

## Locked decisions

All Phase 1 architectural and design decisions live in [docs/adr/](./docs/adr/). **Do not relitigate without an explicit user override.** Each ADR captures the decision + alternatives considered + consequences.

Topics currently locked:
- Surface scope (ADR 0001)
- Model distribution mechanism (ADR 0002)
- Text I/O mechanic (ADR 0003)
- Action set (ADR 0004)
- Model architecture (ADR 0005)
- Memory persistence (ADR 0006)
- Name strategy (ADR 0007)

---

## Sources of truth

- [PRD.md](./PRD.md) — vision, scope, phasing, risks
- [CONTEXT.md](./CONTEXT.md) — domain glossary
- [docs/adr/](./docs/adr/) — locked decisions
- [DESIGN.md](./DESIGN.md) — design contract (tokens, states, motion, microcopy)
- [SWIFTUI-SPEC.md](./SWIFTUI-SPEC.md) — engineering contract
