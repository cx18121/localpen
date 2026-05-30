# ADR 0013 — Calendar context via the user's iCal (ICS) feed, not EventKit

**Status:** Accepted
**Date:** 2026-05-30
**Supersedes:** the *source mechanism* of [ADR 0012](./0012-calendar-readonly-askcontext-chip.md) (EventKit). ADR 0012's product decisions — calendar as a removable AskContext chip, one `calendar:` line in the `<context>` block, persisted on `threads.context_calendar`, rolling 7-day window, titles + times + locations, always-on once enabled — all still hold.

## Context

ADR 0012 read calendar via **EventKit** (`requestFullAccessToEvents` + a predicate query). In practice this could not work on the actual target machine:

- The user runs **macOS 26** (Darwin 25.x) and builds Localpen locally with a **free "Apple Development" certificate**; the app is **not notarized** and is a **menu-bar (LSUIElement) agent**.
- On this configuration, TCC **silently refuses** the calendar request: `requestFullAccessToEvents` returns `false` immediately, **no consent prompt appears**, the authorization status stays `.notDetermined`, and the app never appears in System Settings → Privacy → Calendars.
- This was confirmed empirically after ruling out: status/guard logic, the `EKEventStore` lifetime, missing entitlements (none needed for a non-sandboxed app), launch context (`open` vs Finder), and `get-task-allow` (stripping it did not help). It is a **distribution-trust wall**, not an app-code bug: stricter macOS won't grant Calendar to a non-notarized local build.
- The only EventKit fixes are heavyweight (enroll in the paid Apple Developer Program → Developer ID + notarization), which is overkill for a solo, local tool.

Separately, the user does **not** use Calendar.app and their schedule lives in **Google Calendar** (synced to macOS via CalDAV, but EventKit can't be reached anyway).

## Decision

**Read calendar context from the user's read-only iCal (ICS) feed URL(s) instead of EventKit.** The user pastes their calendar's "secret address in iCal format" (Google: Settings → calendar → Integrate calendar) into Localpen Settings. Localpen fetches those feeds over HTTPS, parses the iCalendar document, expands recurrences for the next 7 days, and renders them through the **existing** `CalendarFormatter` into the **same** chip + `calendar:` prompt line + persistence.

This is a clean swap because ADR 0012 put the source behind a `ContextProbe.CalendarReading` seam: `SystemCalendarReader` (EventKit) is removed; `ICSCalendarReader` (ICS) takes its place. `CalendarEvent`, `CalendarFormatter`, the chip, the prompt line, the `threads.context_calendar` persistence, and the ask-flow race fixes are unchanged.

- **No system permission, no prompt.** The gate becomes `CalendarAccess.isActive = (toggle on) && (≥1 valid feed URL)`. EventKit auth, `NSCalendarsFullAccessUsageDescription`, and the EventKit dependency are removed.
- **Caching.** The network GET is cached (`ICSCalendarCache`, 10-minute TTL, single-flight); the 7-day expansion runs fresh in memory at read time so day labels stay correct. The cache is warmed on launch and when the config changes, so the first ask's chip is populated.
- **Parsing.** A purpose-built, dependency-free parser (`ICSParser`) handles line unfolding, `DTSTART`/`DTEND` with `TZID` / UTC `Z` / floating / `VALUE=DATE` (all-day), `SUMMARY`/`LOCATION` unescaping, `EXDATE`, and `RRULE` expansion (FREQ DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY). It is pure, so it is unit-tested with no network.

## Local-only: the relaxation

ROADMAP commits to **"Local-only, no cloud."** Fetching an iCal feed is a **network request** to the user's calendar provider (e.g. `calendar.google.com`). This ADR **deliberately relaxes** that principle for the *calendar source*, scoped tightly:

- It is **opt-in** (off by default; the user must paste a URL) and **read-only** (HTTP GET; no write path exists in the code).
- The request goes **only to the user's own calendar provider** for the user's own data — no third party, no Localpen server, no telemetry.
- The model remains **fully local**; only the calendar *ingest* touches the network.

The alternative that preserves strict local-only (EventKit) is unavailable here without notarization. Given the user explicitly chose this trade after EventKit was shown blocked, the relaxation is accepted for the opt-in calendar feature only. The broader product stays local-only.

## Consequences

- **It works on the user's machine** with no Apple Developer Program, no notarization, no macOS calendar permission.
- **Secret URL is a credential.** The feed URL grants read access to the calendar; it's stored in `UserDefaults` and shown in Settings with a "keep these private" note. Acceptable for a single-user local tool.
- **Recurrence fidelity is good but not perfect.** `RECURRENCE-ID` instance overrides (a single moved/edited occurrence of a series) are not modeled — such an instance shows at its original slot. Acceptable for "what's my week" context; revisit if it bites.
- **Staleness window.** Up to a 10-minute TTL plus the user's provider sync lag; the chip is a point-in-time snapshot (consistent with ADR 0012's single-capture note).
- **Multiple calendars** are supported (one feed URL per line; events merged), serving the user's several Google accounts.
- **No EventKit dependency** — smaller TCC surface (Localpen now only ever prompts for Accessibility).
