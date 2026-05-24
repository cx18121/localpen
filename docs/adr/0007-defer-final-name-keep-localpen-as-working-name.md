# ADR 0007 — Defer final name decision; keep "Localpen" as the working name through development

**Status:** Accepted
**Date:** 2026-05-24

## Context

The PRD framed "Localpen" as a working name. The name decision was the last item in the grilling pass. None of the technical, design, or architecture decisions depend on the final name — it's a marketing and brand concern, not a load-bearing engineering one. The two main risks to consider before deferring: (a) name might be unusable for legal/availability reasons, in which case we'd want to know now; (b) name might be silently undermining the product positioning.

Due diligence on "Localpen" (performed 2026-05-24):

- **localpen.com** — taken, registered since 2010-10-27 at Dynadot, parked for sale via Brandsly broker. Acquirable but likely four-figure ask.
- **localpen.app** — appears available (no whois record).
- **localpen.ai** — confirmed available ("Domain not found").
- **GitHub** — three existing repos named `localpen`, all small, all dev tooling in the code-playground space (riffing on "CodePen"). None compete in the LLM/writing category. Search collision exists but mitigable by using a longer repo name (`localpen-mac`, etc.) while keeping the user-facing brand short.
- **Mac App Store** — no surfaced result; Mac App Store distribution is out of scope anyway.
- **USPTO trademark** — no hit in general search; conclusive lookup deferred to pre-launch self-service search at tmsearch.uspto.gov.

The name is *viable*. It carries some friction (no .com without acquisition; GitHub collision in adjacent category) but nothing forces a rename today.

## Decision

**Keep "Localpen" as the working name throughout Phase 1 development. Re-evaluate before public launch.**

Specific commitments:

1. PRD, README, CONTEXT.md, ADRs, in-code identifiers, in-UI strings: all use "Localpen" as if it were the final name.
2. **Before public launch (beta or release), revisit the name** in two specific ways: (a) lived-with-the-product check — has the name grown into "this is what it is" or does it still feel like a placeholder? and (b) do a direct USPTO TESS trademark search at tmsearch.uspto.gov.
3. **If keeping Localpen at launch:** acquire `localpen.ai` or `localpen.app` early (cheap, removes surprise). Use `localpen-mac` (or similar) as the GitHub repo name to sidestep the dev-tooling search collision.
4. **If renaming at launch:** do find-and-replace pass across the repo, including ADRs (do not rewrite the ADRs' historical title — append a note pointing at the rename ADR).

## Alternatives considered

1. **Lock "Localpen" as the final name today.** Cheaper psychologically (no more naming on the brain). Rejected: naming under pressure with no shipped product is the worst time to commit. Hoarded .com creates a real future ceiling. Better to revisit with the product in hand.
2. **Rename now to something else.** Investing 30+ minutes in brainstorming. Rejected: the same "names are sticky, better decided after product contact" argument applies to any name, including a new one. We'd be replacing "Localpen" with another not-yet-validated name.
3. **Skip due diligence, just keep Localpen and move on.** Rejected by user's explicit ask to run the checks. Findings turned out to surface real (mild) friction points that are worth documenting now.

## Consequences

- **Design, planning, and implementation proceed under "Localpen".** No name-driven rework expected.
- **Two cheap pre-launch actions queued**: (a) `whois`/registrar check + acquire `localpen.ai` (~$80/yr) or `localpen.app` (~$15/yr) once spend is justified, (b) USPTO TESS direct search.
- **One expensive contingency**: if Localpen takes off and the .com becomes worth pursuing, the broker negotiation could go badly. Acceptable risk — many successful indie Mac apps live without their primary .com (Granola at granola.ai, Linear at linear.app, Cursor at cursor.com via a likely separate acquisition).
- **One quiet UX risk**: "Localpen" reads as wordplay (local + pen) before it reads as a product name. New users may parse it as a play on CodePen given the existing GitHub naming overlap. Watch for this in beta feedback; rename is still on the table at that point.
