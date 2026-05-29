# ADR 0012 — Calendar as a read-only, capture-time AskContext chip

**Status:** Accepted
**Date:** 2026-05-29

## Context

Roadmap sub-project **C (read-only integrations)** begins with a Calendar slice: let the
assistant see the user's schedule as *context* for a free-form Ask, without the tool-calling
framework (sub-project D) existing yet. This is Rung 1 on the capability ladder — **read +
draft, never act**. The open architectural question was *how* calendar context reaches the
prompt before a model-driven tool-calling loop exists.

A design-research pass (3 research dossiers → 3 mechanism proposals → synthesis) evaluated
always-on injection, chip-based opt-in, and intent/keyword triggering. The codebase already
has a strong precedent: `ContextProbe` captures cheap context behind injection seams
(`AXWindowTitleReader`, `SelectionCapturing`) gated by a synchronous trust closure
(`isAccessibilityTrusted`), and `AskContext.from(_:)` lifts probe fields into **removable
chips** rendered above the Ask input. Calendar fits that shape exactly.

## Decision

**Calendar is a read-only EventKit context source that rides the existing `AskContext` chip
pipeline.** On the Ask route, `ContextProbe` reads the user's upcoming events through a new
`CalendarReading` seam (sibling to the AX/selection seams), gated by a synchronous
`isCalendarAuthorized` closure that mirrors `isAccessibilityTrusted`. The formatted string
lands on `Snapshot.calendar` → `AskContext.calendar`, renders as a removable chip, and is
emitted as one `calendar:` line inside the existing `<context>` block in
`ActionPrompts.askUserMessage`.

Settled by the user after the design pass:

- **Scope:** a **rolling 7-day** window; each event shown as **title + start–end time +
  location**. No attendees (the heaviest routine PII). Capped at 8 events with a `(+N more)`
  suffix, grouped by day (Today / Tomorrow / weekday).
- **Always-on once enabled:** every Ask auto-populates the calendar chip; the user drops it
  per-ask before submit. Off by default — enabled once from a Settings toggle.
- **Persisted with the interaction:** the calendar line is stored on the ask thread
  (`threads.context_calendar`, migration v5) so a resumed thread faithfully replays the exact
  prompt the model saw.

**Read-only is structural.** Only `authorizationStatus(for:.event)`,
`predicateForEvents(withStart:end:calendars:)`, and `events(matching:)` are ever called — no
save/remove API exists anywhere in the calendar code path. macOS 14 ships no read-only grant,
so `requestFullAccessToEvents` is used to *read*; write-protection is an app-layer guarantee
(a reviewer can grep the path and find zero write calls), reinforced by the usage-description
copy and the Settings label both saying read-only.

**Permission is lazy.** Never requested at launch or in the hotkey hot path. The hot path only
consults the cheap synchronous gate (`CalendarAccess.isActive` = user toggle ON **and**
authorization == `.fullAccess`); if not active the probe skips the fetch and the Ask proceeds
unblocked. The system dialog (`requestFullAccessToEvents`) fires once from the Settings toggle,
its arbitrary-queue completion hopped to the main actor. `.denied`/`.restricted` degrade
silently — macOS cannot re-prompt programmatically, so there is no nag.

## Alternatives considered

1. **Intent/keyword triggering** (pull calendar only when the question looks schedule-related).
   Rejected: a keyword classifier before tool-calling is brittle — it both misses paraphrases
   and false-fires — and structurally can't show the chip in the pre-submit input rail (the
   trigger is the typed question, which doesn't exist at capture time), breaking lifecycle
   consistency with the app/selection chips. The removable chip already bounds always-on's
   noise, making the heuristic unnecessary.
2. **Today-only, titles+times, ephemeral (the design's own recommendation).** The privacy- and
   token-minimal option. The user chose the wider, persisted variant deliberately, accepting
   the larger footprint for richer schedule reasoning and faithful resume (see Consequences).
3. **A model-driven tool call to fetch calendar.** That is sub-project D. Doing it now would
   pull tool-calling reliability risk forward; Rung 1 deliberately pre-pulls scoped context
   instead.

## Consequences

- **Reuses four shipped, load-bearing precedents** (the probe seam pattern, the synchronous
  auth-closure seam, `AskContext.from` chip-lifting, and `askUserMessage`'s
  `lines.isEmpty` byte-identical invariant) — an unauthorized/empty calendar (`calendar == nil`)
  produces a prompt byte-identical to today's.
- **A second system permission** (EventKit, alongside Accessibility) and a new
  notDetermined/denied/restricted state. `NSCalendarsFullAccessUsageDescription` must live in
  **both** `Localpen/Info.plist` and `project.yml` `info.properties` (the plist is committed
  with `GENERATE_INFOPLIST_FILE: NO` and XcodeGen merges from `project.yml` on regen — miss
  either and a regen drops the key).
- **The system permission dialog overstates intent.** macOS 14 has no read-only grant, so the
  dialog says full (read+write) access while Localpen only reads. Documented in the usage
  copy; enforced by app discipline, not the OS.
- **Always-on injects ~30–80 tokens** of schedule into every Ask, including unrelated ones,
  which can pull a 7B local draft off-topic. Mitigated by the removable chip, the 8-event cap,
  the 7-day bound, and titles/times/locations-only minimization.
- **Persistence trade (chosen knowingly):** the calendar line is written to
  `threads.context_calendar`, so event titles/locations accumulate raw in `history.sqlite` and
  are recoverable via direct DB access. **The Forget tombstone does NOT protect it** —
  `forgotten_before` is a query-time filter on export + memory inference, not an erasure; it
  never touches the `threads` table. `Clear History` (`DELETE FROM threads`) does remove it.
  Calendar text is stored on the thread, **not** on the seed `Interaction`'s
  `selection`/`custom_prompt`, so it never enters the interactions export or
  `MemoryAttribution` voice/facts inference.
- **Point-in-time snapshot:** the calendar is read once at capture and frozen for the thread's
  life (the probe's single-capture invariant). A long-open thread shows a stale schedule, not
  a live one — by design, documented in code so it isn't mistaken for a bug.
- **Read-only stays read-only.** Graduating to creating/editing events is Rung 2 (sub-project
  D) and requires a new ADR; this ADR does not authorize any write path.
