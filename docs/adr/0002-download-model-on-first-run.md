# ADR 0002 — Download the default model on first run; do not bundle it

**Status:** Accepted
**Date:** 2026-05-23

## Context

Phase 1 ships exactly one curated local model. The candidate (Qwen 2.5 7B Instruct or Llama 3.2 8B, decision pending) is ~4–5 GB at Q4_K_M. Three feasible strategies for getting it onto the user's machine:

- **A. Bundle in .dmg.** ~4–5 GB installer. First run works offline, instantly. .dmg is unusually large; Sparkle delta updates trickier; notarization slow.
- **B. Download on first run.** ~50 MB .dmg. User sees a download progress bar on first launch, ~4–5 GB transfer, multiple minutes on broadband. Requires network on first run. Standard pattern for the category (Ollama, LM Studio, Jan).
- **C. Bundle a small model, offer a bigger one.** ~2 GB .dmg with Qwen 2.5 3B. Works immediately on first run; "upgrade to recommended model" nudge for bigger Macs.

The PRD originally claimed an "invisible default" principle — no config dialogs, auto-pick a model, "user sees a chat panel and a friendly message." That principle pushed toward A or C. It has been removed (see PRD update accompanying this ADR): Phase 1's audience is technical (r/LocalLLaMA, HN), and a download progress bar on first launch is normal and even expected in this category. The "invisible default" pitch is a Phase 3 promise, not v1.

## Decision

**Phase 1 downloads the default model on first run (Strategy B).**

- The `.dmg` ships small (target <100 MB) — app shell, llama.cpp dynamic libs, no GGUF weights.
- On first launch, the app prompts the user (one click) to download the default model. Progress bar visible. Cancel allowed.
- The user cannot use the quick-action surface until the model finishes downloading. The Phase 1 UI must have a coherent "model downloading" state on the NSPanel.
- The downloaded GGUF is stored in a unified model store at a stable on-disk location, addressable by name (no Ollama-style content-hashed re-storage).
- Distribution mechanism (.dmg + Sparkle, Homebrew cask, GitHub binary, etc.) is **not load-bearing** for this decision and is treated as an architecture choice — see PRD architecture section.

## Alternatives considered

1. **Bundle in .dmg (A).** Honors offline-first day-1 use, but the .dmg is heavyweight to ship, slow to notarize, and Sparkle updates either re-deliver the model or split into a two-channel pipeline. Audience tolerance for first-run downloads is high in this category, so the cost of B is real but small.
2. **Bundle small model + nudge bigger (C).** Best UX on paper. But the bundled-small model has to be good enough to not embarrass the product on first impression, and a tiered "default model + recommended model" story is a config dialog by another name — exactly what the user explicitly deprioritized when they dropped "invisible default" from the principles.

## Consequences

- **First-run UX is now an explicit Phase 1 design surface.** Impeccable / swiftui-expert must design: model picker (just one option in v1, but framed for future), download progress, download error/retry, "model ready" handoff to the quick-action surface, and the empty/loading state of the NSPanel before the model exists.
- **Network is required on first run.** Offline-first installation is sacrificed. The app itself runs offline once the model is downloaded — the local-first promise of the product is preserved.
- **No bundled-model fallback for sandbox-restricted environments.** Not a concern in Phase 1 (no MAS distribution).
- **Power-user toggle remains useful** — letting users pick a different model from a list during or after first-run is a natural extension of the download flow.
- **Sparkle update flow only ships app code**, not models. Model updates are a separate (eventually-needed) channel — out of Phase 1 scope.
