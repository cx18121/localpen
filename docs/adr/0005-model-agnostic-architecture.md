# ADR 0005 — Model-agnostic Phase 1 architecture; Qwen 2.5 7B as soft v1 default

**Status:** Accepted
**Date:** 2026-05-24

## Context

The PRD's *Open questions* section asks "v1 default model: Qwen 2.5 7B Instruct? Llama 3.1 8B?" The original framing treated this as a load-bearing decision. It isn't.

Per ADR 0002 (download on first run), Localpen does not redistribute model weights — it fetches them from the model author's hosted location (HuggingFace, etc.). So license distinctions between candidate models matter for marketing optics but not for distribution mechanics. And per the user's roadmap, automatic chip+memory-based model selection arrives in a later phase; the v1 default is a placeholder that will be either supplemented or replaced.

What is load-bearing is whether Phase 1's *architecture* can accept different models without code changes. If yes, "which model is default" is a config tweak. If no, every future model change is a refactor.

## Decision

**Phase 1 is built model-agnostic. The default model is selected at config time, not compile time.**

Concrete commitments:

1. **All model-specific knobs live in config**, not in code:
   - GGUF download URL + expected size + checksum.
   - System-prompt template per Action (Proofread, Polish, More formal, More casual, Shorter).
   - Sampling parameters (temperature, top_p, top_k, repetition penalty).
   - Context-window size.
   - Stop tokens, chat template (Qwen ChatML vs. Llama-3-instruct vs. Gemma).
   Switching to a different GGUF = updating config, no Swift code touched.

2. **The v1 soft default is Qwen 2.5 7B Instruct, Q4_K_M.** Chosen for: best-in-class instruction-following at the 7B size (load-bearing for action precision), Apache 2.0 license (cleanest OSS optics even though redistribution isn't happening), 32K context, strong multilingual (sets up Phase 1.5 Translate without a swap), ~4.4 GB download (low end of candidate range). Soft because: if empirical testing on the user's own prose pre-launch shows Llama 3.1 8B or another candidate is meaningfully better for the v1 action set, swap the config — no further ADR required.

3. **Hardware fingerprint is collected silently from first run.** Chip family (`sysctl hw.machine`, `hw.model`), total unified memory, free disk space. Stored locally, no UI exposure, no telemetry. Phase 2+ auto-pick reads this data; collecting from day 1 avoids a cold-start for early users when auto-pick ships.

## Alternatives considered

1. **Hardcode Qwen 2.5 7B everywhere.** Simpler Phase 1; faster to ship. Rejected: every future model change becomes a code change. Defeats the eventual auto-pick goal.
2. **Ship auto-pick logic from Phase 1.** Reads fingerprint, picks model, downloads. Rejected as scope creep — auto-pick policy (chip × memory → recommended model) requires empirical testing of multiple models on multiple Macs, which is its own project. Phase 1 ships one curated default.
3. **Defer fingerprint collection to Phase 2.** Reasonable, but cheap to add now, expensive to retrofit retroactively across users. Cost asymmetry favors collecting from day 1.

## Consequences

- **The Phase 1 design surface gains a config file** (likely YAML or TOML) shipped with the app, documented, easy to point Power Users at. Custom-model support becomes "edit this file, restart Localpen" — natural Power-User affordance without dedicated UI.
- **Action prompt engineering becomes a co-evolving artifact** with the model choice. If we swap default model later, the prompt templates may need a pass too. Acceptable — the prompts are config, not code.
- **The "v1 default model" line in the PRD's Open Questions becomes resolved** — Qwen 2.5 7B Instruct, soft commit. Open Question removed.
- **Phase 2 auto-pick gets a paved path** — model registry already exists in config, fingerprint already collected. Auto-pick is "read fingerprint, look up policy table, set active model in config."
- **First-run flow includes a discreet 'change model' affordance** behind a "Power User" / "advanced" disclosure. Not a full picker UI — just a way to point at a different config-listed model before the download starts. (Detailed in design phase.)
