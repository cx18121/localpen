# ADR 0019 — A generalized capture-time `ContextSource` seam, distinct from the brain

**Status:** Accepted
**Date:** 2026-06-02
**Related:** generalizes the calendar slice ([ADR 0012](./0012-calendar-readonly-askcontext-chip.md) / [ADR 0013](./0013-calendar-via-ics-feed.md)); deliberately excludes the knowledge brain ([ADR 0014](./0014-brain-derived-fts5-index-over-vault.md)). Implements roadmap sub-project **C** (read-only integrations), Rung 1 (read + draft, never act).

## Context

Sub-project C adds more read-only context to a free-form Ask: **Files**, **screen-OCR**, and **Mail**, alongside the existing **Calendar**. The planning question was whether these — plus the brain — share one abstraction.

Inspecting the live code surfaced that the two context mechanisms already in the app are **not** the same shape; they split by *when* context is read:

- **Capture-time** (app/window, selection, calendar): read at hotkey via `ContextProbe` behind `Sendable` reader seams, gated by a synchronous trust closure, frozen for the session, lifted into `AskContext`, rendered as a **removable chip**, emitted as one line in the `<context>` block, and persisted per-source (`threads.context_calendar`, v5). Query-**independent**.
- **Query-time** (the brain): read at stream via `ContextEngine.bundle(for: query)`, relevance-ranked (bm25 + backlinks), surfaced as **provenance** under the answer (`context_knowledge`, v6). Query-**dependent**.

Calendar, Files, screen-OCR, and Mail are all capture-time/query-independent ("what's around you right now"). The brain is the lone query-time source, different on purpose.

## Decision

**Define one `ContextSource` seam for the capture-time family; leave the brain's query-time engine separate. Do not unify them.**

```
protocol ContextSource: Sendable {
    var kind: ContextKind { get }          // .app .calendar .files .screen .mail
    var isEnabled: @Sendable () -> Bool    // Settings toggle + authorization (the isCalendarAuthorized pattern)
    func capture() async -> ContextItem?   // async; nil = disabled / nothing to add
}
struct ContextItem: Codable, Equatable, Sendable { let kind: ContextKind; let chipText: String; let promptLine: String }
```

- `ContextProbe` runs every **enabled** source's `capture()` **concurrently** at capture time and collects `[ContextItem]`.
- `AskContext` gains `sources: [ContextItem]`, **replacing** the explicit `appLabel` and `calendar` fields. One chip renderer loops the list; one prompt loop emits the lines.
- Persisted as a **single `context_sources` JSON column** (migration **v7**); the existing `context_calendar` is folded forward so resumed threads replay faithfully (the existing replay tests are the safety net).
- `capture()` is **async** — calendar is cached-sync today, but screen-OCR and file reads are inherently async; async is the general case.
- **`selection` and `knowledge` stay first-class and out of the list.** `selection` is the *operand* a transform acts on (it drives `Action.ask(withSelection:)` / `hasSelection`); `knowledge` is the brain (query-time seam). Only *ambient* sources generalize.

Each source: **off by default**, enabled from a Settings toggle, gated by a synchronous authorization closure, **always-on-once-enabled** with a per-ask removable chip (calendar's model).

### Build order and per-source notes

1. **Files** — the *frontmost open document* via the AX `kAXDocumentAttribute` (reuses the AX permission Localpen already holds; no new prompt) **first**; *Finder selection* (needs an Automation permission) **second**. Reads plain text directly + PDF via PDFKit, capped like `perPageCharCap`; rich formats contribute filename only; nil when there's no document. Building Files *is* how the seam is extracted, which de-risks the rest.
2. **screen-OCR** — ScreenCaptureKit + Vision. Its always-on-vs-explicit-grab privacy/trigger model is decided at *its* build time, not here.
3. **Mail** — **real mail, not OCR.** Recommended path is the **Mail.app local store** (the user connects Gmail → Mail.app once; macOS performs the OAuth + sync; Localpen reads the local store — the same "connect at the OS level, read locally" shape as the Calendar ICS feed, so it stays local-only). An **in-app Gmail OAuth/API** is the documented fallback if the local store proves unreadable, but it puts a cloud client inside an open-source app and strains the local-only commitment, so it needs **its own ADR** before it's built. Decided at build time.

## Alternatives considered

- **One unified context abstraction including the brain.** Rejected: it would force the brain's relevance-ranked, question-dependent, provenance-surfaced retrieval into a capture-time chip protocol, making both worse. The timing difference is fundamental, not incidental.
- **Extend the explicit per-source pattern** (a named `AskContext` field + migration column per source). Rejected: with ~5 capture-time sources, `AskContext` and the thread schema bloat one field/column each, and the shared abstraction stays an implicit convention rather than a type. The generalized list is the actual seam; new sources then cost ~nothing.
- **Mail via screen-OCR.** Rejected by the user: OCR'd mail is a weak substitute for real mail data, and only covers mail currently on screen. Mail should read actual messages (locally, per above).

## Consequences

- Files / screen-OCR / Mail each become "implement one `ContextSource`" — one chip pipeline, one prompt loop, one persisted column, one permission pattern.
- A v7 migration touches the persisted thread schema and the replay path; the existing calendar/selection replay tests guard it.
- The brain stays its own seam; a future change that tried to fold query-time retrieval into `ContextSource` (or vice versa) should reopen this ADR.
- The in-app-Gmail question is explicitly deferred to a future ADR so the local-only line ("no cloud **model**"; network fetch of *your own* data is allowed, per ADR 0013) is decided deliberately, not by drift.
