# Localpen — PRD

*Working name. Subject to change. Captures the two things that matter: it's **local** (runs on your machine, your data never leaves) and it's a **pen** (a writing tool).*

---

## Vision

A native macOS writing companion that lives in a small floating sidebar, watches what you're writing in any app, and helps you write better — entirely on your computer, using open-source AI models. No cloud. No login. No subscription.

The thesis: **right now, you keep ChatGPT open in a separate tab and shuttle text back and forth all day.** Localpen is the layer that ends the shuttle.

## The problem

Writing assistance today is fragmented by surface:
- Email in Mail → Apple Writing Tools (Apple's 3B model only; limited app coverage; no memory)
- Email in Gmail web → nothing
- Slack / Discord messages → nothing
- GitHub READMEs → nothing
- Word docs → Microsoft's AI (cloud, login)
- Notion → Notion AI (cloud, $10/mo)
- Cursor → great for code, not for prose

Everyone compensates by keeping ChatGPT open in a sidebar tab and copying / pasting / instructing / pasting back. That's the actual pain. It's a four-step shuttle every time.

For local AI specifically: the existing tools (Ollama, LM Studio, Jan, Open WebUI) are built for power users. Setup involves CLI, Docker, model picker UIs with quantization choices. **A non-technical person — a parent, a grandparent, a student who's not a developer — cannot use local AI today.** That market is essentially empty.

## Why local matters

Every piece of text you select is private:
- Drafts of sensitive emails (boss, ex, lawyer, doctor)
- Personal messages
- Work documents under NDA
- Source code with proprietary logic
- Journal entries, letters, anything not-yet-shared

Cloud AI requires you to trust the provider with all of that, forever. Local AI doesn't.

The secondary "why local": it's also faster (no network round-trip), free (no per-token charges), and works offline.

## Target user — phased

- **Phase 0–1:** technical early adopters. r/LocalLLaMA, Hacker News, GitHub-OSS-friendly crowd. They're actively shopping for an Ollama alternative; they value the technical pitch ("native macOS, llama.cpp-first, MLX, privacy-respecting"). This is where the project earns its first stars.
- **Phase 2:** writers, researchers, knowledge workers who heard about local AI and want to try it without the setup pain. Mac-centric "Setapp / Bear / Notion" audience.
- **Phase 3:** non-technical users. Parents, grandparents, students, anyone who wants ChatGPT-quality writing help but doesn't trust the cloud. Apple Intelligence Writing Tools confirms this category is real; Localpen's version wins on bigger-models, app-coverage, memory, and ownership.

## Product shape

A small native macOS floating panel — Granola-shaped — that lives alongside your active app. Anchored where you place it.

Watches the active text field via the macOS Accessibility API. When you select text in *any* app (Mail, Slack, Cursor, Gmail-in-Chrome, Notion, Notes, Word, GitHub, anywhere a text field lives), the companion can see the selection and offer help.

Two interaction **surfaces** share the same NSPanel, shipped in stages:

1. **Quick-action surface (Phase 1):** global hotkey opens the panel with the selected text and an action menu. Pick an action, watch the result stream in, paste back into the source app. Transient — the panel dismisses after use. Latency target: <500ms hotkey-to-first-token.
2. **Conversational surface (Phase 1.5):** the same panel becomes persistent and multi-turn. Proactively notices things ("this email reads tense — soften?"), accepts free-form chat ("make this more formal", "give me three opening lines"), keeps history visible. Built on top of the quick-action plumbing.

Memory is implicit. From Phase 2 onward, the companion learns your writing voice over time, references past sessions naturally ("you usually open emails to Sarah with 'Hi' not 'Hey'"), and never asks you to manage a separate memory UI.

## Phasing

| Phase | Scope | Goal |
|---|---|---|
| **1. The slab — quick action** | Hotkey-triggered NSPanel + action menu + 1 curated local model. Streams result, pastes back. No conversation. No memory. Polish until it feels native. | Quick-action parity with Apple Writing Tools, but in every app. Latency <500ms hotkey-to-first-token. |
| **1.5. Conversation** | Same NSPanel becomes persistent and multi-turn. Free-form chat, message history, proactive nudges. Still no memory. | One surface, two modes. The product-shape vision realized. |
| **2. Memory** | Persistent memory of your style. "Knows your voice." | Subsequent rewrites match how you actually write. |
| **3. Personalities** | Curated personas ("professional", "casual", "academic", custom). Per-conversation switching. | One AI surface, many tones. |
| **4. Agent** | Tool calling. "Reply to that email saying yes" pulls calendar + thread context + past replies. | Stops being a writing tool, starts being a personal assistant. |
| **5. Voice & cross-platform** | Voice-to-text input (Wispr-style). Eventually Windows / Linux. | Reach beyond Mac power users. |

Phase 1 is the entire product. If the slab doesn't feel right, none of the later phases save it.

## Key principles

1. **Interface quality is the gate.** This product lives or dies on how the panel feels. Polish > features.
2. **Power users get the full surface.** Phase 1's audience is technical — they expect to see model choice, quant selection, system prompts. Don't hide what they came for. The "invisible default" pitch is a Phase 3 promise, not a v1 one.
3. **Open source, OSI-licensed from day one.** No "All rights reserved" mess (cf. Open WebUI's reputation problem).
4. **Local-first, no cloud option.** Adding a cloud fallback would dilute the central promise. Don't.

## Technical architecture (sketch)

- **App shell:** Swift / SwiftUI, native macOS (no Electron, no Tauri)
- **Inference backend:** llama.cpp via SPM dependency, with Metal acceleration; MLX backend behind a toggle for Apple Silicon
- **Local HTTP server:** `llama-server` auto-spawned and lifecycle-managed
- **Selection capture / write-back:** macOS Accessibility API
- **Global hotkey:** `sindresorhus/KeyboardShortcuts` SPM package (see [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md))
- **Floating panel:** `NSPanel` with custom styling (the SwiftQuickPanel pattern)
- **Memory:** SQLite, local file
- **Model storage:** unified GGUF store — no re-hashing à la Ollama
- **Distribution:** signed + notarized .dmg, Sparkle for updates, GitHub Releases, eventually Homebrew cask
-

## The wedge

The macOS-native, llama.cpp-first, OSI-licensed, polished-UX slot is empty. Verified competitive landscape:
- **Ollama** (172k stars): trust collapsing. "Ollama's enshitification has begun" — 1,334 upvotes on r/LocalLLaMA Nov 2025; "Why I quit Ollama" — 520 upvotes Dec 2024. CLI-first; no native UX.
- **LM Studio**: closed-source. Recent malware rumors (unverified but signal-rich). Going more paid.
- **Jan** (42.6k stars): OSS, but Tauri/Electron, not native; ships its own `cortex.cpp` wrapper layer.
- **Lemonade** (4.1k stars): the strongest spiritual answer to "llama.cpp-first" — but **AMD/Ryzen-AI-NPU-centric, no real Apple Silicon story.**
- **Open WebUI** (138k stars): non-OSI "All rights reserved" license (verified). Community grievance.
- **GPT4All** (77k stars): dead (last commit May 2025).
- **Apple Foundation Models**: locked to Apple's 3B model; only works in apps that opt into Apple's text APIs (most Electron apps don't get it).

The exact slice — native SwiftUI + llama.cpp + Ollama-compat shim + unified model store + Apple Silicon first — is empty. Verified as of 2026-05-23. One five-day-old empty repo (`Sahil-Sandilya/MacLLM`) is the only entrant; worth tracking but currently zero traction.

## Risks (honest)

- **llama.cpp release cadence:** ~10 builds/day; ~30 documented REST API breaking changes in the last year. Maintenance: 4–8 hours/week sustained, spiking to 10+ when a breaking change lands. Mitigation: pin to monthly snapshots, don't chase HEAD.
- **Apple notarization for daemon apps:** non-trivial but well-trodden (Ollama, LM Studio both notarize their .dmg). $99/yr Apple Developer Program required.
- **Apple Foundation Models scaling:** Apple will grow their on-device model from 3B → 8B+ over time. Erodes the lowest end of Localpen's wedge. Countermove: support *any* model, not Apple's one.

## Open questions

- Final name (Localpen is the working name; rebrand later possible).
- First "agent" tool in Phase 4: Mail? Calendar? Files? cxkb vault integration?
- Distribution narrative: lead with the OSS / privacy story (technical adopters) or the consumer / ease-of-use story (broader)?
