# Localpen — project-level instructions for Claude Code

> Auto-loaded into every Claude Code session in this directory. Terse on purpose — every line costs context budget on every turn.

## What this is

Localpen is a native macOS writing companion. Phase 1 = "the slab" — a floating NSPanel with a 6-action quick-action surface, local llama.cpp inference, no cloud. Vision committed; design + engineering specs locked; code starts after `PLAN.md` is written.

The user's personal `~/.claude/CLAUDE.md` covers general working style. This file doesn't repeat it.

## Doc reading order (when joining cold)

Read in this order before doing project work:

All project docs live in [docs/](./docs/), which is gitignored (local-only, not in the repo).

1. [docs/PRD.md](./docs/PRD.md) — original vision + market analysis (target-user phasing & distribution are historical)
2. [docs/ROADMAP.md](./docs/ROADMAP.md) — **live north star + build sequence** (supersedes PRD phasing)
3. [docs/CONTEXT.md](./docs/CONTEXT.md) — domain glossary (surfaces, operations, action, interaction)
4. [docs/adr/](./docs/adr/) — locked architectural decisions (numeric order)
5. [docs/DESIGN.md](./docs/DESIGN.md) — design contract
6. [docs/SWIFTUI-SPEC.md](./docs/SWIFTUI-SPEC.md) — engineering contract
7. [docs/PRODUCT.md](./docs/PRODUCT.md) — impeccable's product-register file
8. [docs/PLAN.md](./docs/PLAN.md) — Phase 1 build plan (when it exists)

## Locked decisions

ADRs in [docs/adr/](./docs/adr/) are **immutable** unless the user explicitly says "let's revisit ADR X." Don't propose alternatives in a new conversation — the alternatives have already been considered and named in each ADR's "Alternatives considered" section.

Current Phase 1 ADRs:

- **0001** — Phase 1 ships quick-action surface only; conversational = Phase 1.5
- **0002** — Download model on first run; do not bundle
- **0003** — Clipboard-mediated text I/O (synthetic ⌘C/⌘V); no AX tree-walking
- **0004** — v1 action set: Proofread / Polish / More formal / More casual / Shorter / Custom
- **0005** — Model-agnostic architecture; Qwen 2.5 7B Instruct as soft default
- **0006** — Persist every interaction from day 1; minimal SQLite schema
- **0007** — Defer final name; "Localpen" stays as working name through development

## Workflow conventions

This project follows: **grill → design → spec → plan → build**.

- `grill-with-docs` skill — surfaces contradictions, locks decisions into docs/CONTEXT.md + ADRs
- `impeccable` skill — design vision (docs/DESIGN-BRIEF.md sketch → docs/DESIGN.md production)
- `swiftui-expert-skill` — engineering spec (docs/SWIFTUI-SPEC.md)
- `docs/PLAN.md` — task breakdown for execution
- code — written against docs/PLAN.md, atomic commits

Decisions get locked into ADRs **as they crystallize**, not batched at the end. If a non-trivial decision is made in a conversation, write an ADR before moving on.

## Discipline rules

1. **Don't relitigate ADRs.** If the user does want to revisit one, write a new ADR superseding the old; don't silently flip the decision.
2. **Don't drift from DESIGN.md tokens.** Specific oklch values and spacing rhythm are committed. Color / spacing tweaks need a design pass, not inline guessing.
3. **No code in spec docs.** SWIFTUI-SPEC.md describes types + integration points; actual Swift code lives in source files once they exist.
4. **Respect Phase 1 scope.** "What this doesn't include" is named in DESIGN.md §7 and SWIFTUI-SPEC.md §16. Don't add features beyond those lists without an explicit user prompt.
5. **Throwaway artifacts get deleted.** `sketches/` is the only throwaway and should be cleaned up after PLAN.md is written.

## Project state pointers

- Working name: **Localpen**
- macOS deployment target: **14 (Sonoma)** minimum
- Default v1 model: **Qwen 2.5 7B Instruct, Q4_K_M**
- Default hotkey: **⌃⌥Space**
- SPM deps: KeyboardShortcuts · GRDB.swift · TOMLKit · DynamicNotchKit (see [ADR 0008](./docs/adr/0008-keyboardshortcuts-instead-of-masshortcut.md) + [ADR 0011](./docs/adr/0011-notch-surface-supersedes-floating-slab.md))
- Pre-launch checklist lives in [docs/adr/0007-defer-final-name-keep-localpen-as-working-name.md](./docs/adr/0007-defer-final-name-keep-localpen-as-working-name.md) and the README.

## When to ask the user

Ask before:
- Reversing or significantly amending any ADR
- Adding a new SPM dependency beyond the three already chosen
- Changing the macOS deployment target
- Renaming the project
- Locking the final visual treatment of a state that DESIGN.md left as "decide in pass 2" (none currently)

Proceed without asking for: any task explicitly scoped by PRD / DESIGN.md / SWIFTUI-SPEC.md / PLAN.md.
