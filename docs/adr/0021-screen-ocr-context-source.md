# ADR 0021 — Screen-OCR context source: window-scoped, viewport-only

**Status:** Accepted
**Date:** 2026-06-05
**Related:** the screen source planned in [ADR 0019](./0019-context-source-seam.md); opt-in per [ADR 0020](./0020-opt-in-context-sources.md). Decided via a grill + two feasibility spikes.

## Context

The last roadmap-C source: OCR what's on screen as ask context. A naive "OCR the screen" is the obvious shape and the wrong one. Two unknowns had to be retired before building — the same diligence Calendar skipped (it shipped reading nothing) and Mail honored.

**Spike findings (verified, not assumed):**
- **Full-screen OCR is noise.** A captured 1710×1107 frame OCR'd to a soup of menu bar, the clock, and fragments from ~27 windows interleaved in reading order — low-signal as context.
- **Single-window OCR is clean.** Capturing one window's surface (via `SCContentFilter(desktopIndependentWindow:)`) yields that window's coherent text only. Window capture grabs the surface, so the notch occluding the window doesn't matter.
- **Capture + OCR is cheap + accurate:** ~160ms capture, ~1s Vision OCR, correct text.
- **Permission is obtainable by THIS app.** The risk was the Calendar-class failure (EventKit silently refused the non-notarized app). Screen Recording is a *manual System-Settings* grant like Full Disk Access, not a prompt+entitlement — and an in-app spike confirmed Localpen appears in the Screen Recording list, the grant sticks, and capture then returns real pixels.

## Decision

**OCR the frontmost window the user summoned from — the visible viewport — opt-in via the `+ Screen` tray.**

- **Window, not screen.** Capture the frontmost on-screen window owned by the held **summon pid** (like Files holds it; once the notch opens Localpen is frontmost, so the pid is captured before that). The whole window is OCR'd, **chrome included** (a few junk lines like a URL the model ignores) — content-region cropping was rejected as a fragile per-app rabbit hole for marginal gain.
- **Viewport only.** Only what's rendered is captured; scrolling to page 6 is not included. An honest contract — whole-document retrieval is a different mechanism we deliberately don't smuggle in under "screen."
- **Lazy + opt-in (ADR 0020).** Nothing is captured until the user taps `+ Screen`; the first tap with no grant calls `CGRequestScreenCaptureAccess()` (adds Localpen to the list) and attaches nothing, rather than a silent black frame.
- **Mechanism:** ScreenCaptureKit (`SCScreenshotManager`) + Vision (`VNRecognizeTextRequest`), capped via `ContextEngine.condense`. `ScreenAccess` Settings toggle gates availability; capture returns nil (no chip) without a grant / window / text.

## Its niche is narrow — and that's fine

For native apps, selection and Files (AX document read) give *cleaner* text than OCR. Screen-OCR earns its keep only where text is **visible but unreachable**: browser-rendered PDFs, images, video frames, Electron/remote apps with poor accessibility. The motivating case was a homework PDF open in Chrome (Chrome's AX "document" is a URL, and its PDF-viewer selection is flaky). We build for that case and accept the redundancy elsewhere.

## Alternatives considered

- **OCR the full screen.** Rejected: empirically noise (menu bar + many windows).
- **Crop to content region.** Rejected: no reliable content-rect API; fragile across apps.
- **Read browser text via deep AX tree-walking.** Rejected: contradicts [ADR 0003](./0003-clipboard-mediated-text-io.md) and is fragile; OCR is robust against *whatever is rendered*.
- **Scroll-and-stitch the whole document.** Rejected: fragile, and out of scope (viewport contract).

## Consequences

- New `ScreenCapture` (SCK + Vision) + `ScreenAccess` + `ContextItem.screen`; one `addAskSource(.screen)` case and one `availableAskSources` entry. `ContextKind.screen` already existed (rank 3).
- Adds a second TCC dependency (Screen Recording, after Mail's Full Disk Access). Verified obtainable.
- Pipeline is GUI-context-dependent (`SCContentFilter(desktopIndependentWindow:)` needs the WindowServer connection a real app has; a bare CLI crashes) — fine in-app, noted so it isn't re-litigated from a script.
