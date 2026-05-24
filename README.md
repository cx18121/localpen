# Localpen

A native macOS writing companion. Local AI. Lives next to whatever you're writing in.

**Working name** — see [PRD.md](./PRD.md) for the full vision and [docs/adr/0007](./docs/adr/0007-defer-final-name-keep-localpen-as-working-name.md) for the naming stance.

## Status

**Phase 0 → Phase 1.** Vision committed, design contract locked, engineering spec locked, build plan in progress. No code yet.

Read the docs below in order if you're joining the project cold.

## Documentation

| Doc | What it is |
|---|---|
| [PRD.md](./PRD.md) | Vision, target user, the wedge, the risks |
| [CONTEXT.md](./CONTEXT.md) | Domain glossary — surfaces, operations, action, interaction |
| [docs/adr/](./docs/adr/) | Locked architectural decisions (7 ADRs as of Phase 1) |
| [DESIGN.md](./DESIGN.md) | Design contract: tokens, panel anatomy, state catalog, motion, microcopy |
| [SWIFTUI-SPEC.md](./SWIFTUI-SPEC.md) | Engineering contract: deployment target, architecture, view hierarchy, services |
| [PRODUCT.md](./PRODUCT.md) | impeccable's product-register file: users, voice, anchors, anti-references |
| [CLAUDE.md](./CLAUDE.md) | Project-level instructions for AI tools |
| [PLAN.md](./PLAN.md) | Phase 1 task breakdown (M0 → M9) |
| [PHASE-1.5-BRIEF.md](./PHASE-1.5-BRIEF.md) | One-pager preview of the next phase. Grilled into a real plan only after Phase 1 ships. |
| [DESIGN-BRIEF.md](./DESIGN-BRIEF.md) | Sketch/mid-fi exploration that fed into DESIGN.md (historical artifact) |

## Pre-launch checklist

Stays parked here until claimed:

- USPTO TESS direct trademark search for "Localpen"
- Acquire `localpen.ai` or `localpen.app` once name commits (per [ADR 0007](./docs/adr/0007-defer-final-name-keep-localpen-as-working-name.md))
- 50-line Swift PoC: verify synthetic ⌘C/⌘V round-trip in Slack / Cursor / Discord / Gmail-in-Chrome / Notion (per [ADR 0003](./docs/adr/0003-clipboard-mediated-text-io.md))

## Reference

The earlier UI prototype that validated Variant A — Conversation lives at `../writing-companion-prototype/`.
