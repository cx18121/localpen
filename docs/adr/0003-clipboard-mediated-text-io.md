# ADR 0003 — Clipboard-mediated text I/O; no AX tree-walking in Phase 1

**Status:** Accepted
**Date:** 2026-05-24

## Context

Phase 1's quick-action surface needs to (a) capture the user's selected text from any app on hotkey, and (b) write a model-generated result back into that same app's text field after acceptance. The PRD originally implied this would happen via direct macOS Accessibility API (AX) tree-walking — read `AXSelectedText`, write `AXSelectedTextValue`.

AX coverage is patchy in real-world apps:

- Native AppKit (Mail, Notes, TextEdit): full AX support, reads and writes work.
- Catalyst (Messages): partial.
- Electron (Slack, Discord, VS Code, Cursor, Notion desktop): inconsistent; reads sometimes work, writes often silently fail.
- Chrome web pages (Gmail-in-Chrome): exposes an AX tree but text-field writes through it are unreliable.

Localpen's PRD-stated target app list — Mail, Slack, Cursor, Gmail-in-Chrome, Notion — is mostly Electron/Chromium. AX direct-write is **not reliable** across that surface. The silent-failure mode (text appears in the panel, user accepts, nothing happens in the source app) is the worst possible UX for a "polish > features" product.

Apple Writing Tools sidesteps this because Apple owns NSTextView at the OS level — its direct write-back path isn't available to third-party apps. The right peer comparison for Localpen is third-party Mac tools doing similar text-into-other-apps work: Raycast AI, Superhuman command bar, Alfred. All of them use clipboard-mediated text I/O.

## Decision

**Phase 1 uses clipboard-mediated text I/O for both selection capture and paste-back. No AX tree-walking for text content.**

Flow:

1. **On hotkey:** save current pasteboard contents → post synthetic ⌘C to active app → wait ~30–50ms → read pasteboard → that string is the captured selection. If pasteboard is unchanged (no selection or app blocked the copy), open the panel empty and accept a free-form prompt.
2. **On accept:** write model result to pasteboard → re-activate the original frontmost app (tracked at hotkey time) → post synthetic ⌘V → wait ~100ms for paste to land → restore original pasteboard contents.

AX permission is still required (CGEvent posting requires it), but the AX UI tree is not walked for text. We only inspect AX for active-app/window identity, not for individual text-field contents.

## Alternatives considered

1. **Pure AX read/write.** Cleanest in theory; ~0ms overhead; doesn't touch clipboard. Rejected: silent failure mode in the dominant Electron portion of the target app list. Shipping a product that quietly doesn't work in Slack is worse than touching the clipboard.
2. **Hybrid AX → paste fallback.** Try AX first, fall back to clipboard on detected failure. Rejected for Phase 1: detection logic for AX-write success is itself unreliable (writes can "succeed" without the text appearing), per-app allow/deny lists become a maintenance burden, two code paths double the surface area. May be revisited in Phase 2+ as an optimization for native AppKit apps.
3. **AX read, paste write.** AX reads tend to be more reliable than AX writes. Rejected: AX reads also fail in Electron (Slack/Cursor selectedText is unreliable), so we'd still need the clipboard fallback for reads — back to two code paths for marginal upside.
4. **Panel-only, no paste-back.** User copies result manually from the panel. Rejected: violates the "end the shuttle" thesis. If we don't paste back, we've shipped ChatGPT-in-a-sidebar.

## Consequences

- **One code path** for text I/O across every app. No per-app testing matrix; no Electron AX swamp; no maintenance treadmill as Slack/Cursor ship Electron updates.
- **Clipboard is briefly touched.** The polished result lives on the system pasteboard for ~100ms between write and restore. Clipboard managers (Raycast, Maccy, Pastebot) may capture this intermediate value. Acceptable trade-off; document for users; consider an advanced "don't restore clipboard" toggle in a later phase.
- **AX permission is still required** at install time (for synthetic-keystroke posting and active-app detection). The user-facing permission story is unchanged.
- **README "next step #1" — the 50-line Swift PoC — narrows in scope.** Instead of "does AX read+write work in Slack/Cursor/Discord/Gmail/Notion?", the PoC validates: "does synthetic ⌘C + pasteboard read + synthetic ⌘V + pasteboard restore work in each, without app-specific quirks?" Faster, more conclusive, lower bar.
- **Phase 1.5's proactive nudges** ("this email reads tense") require passive text observation, which is *not* possible via clipboard. That capability is naturally pushed to Phase 1.5+, where AX read on a per-app whitelist (only apps with reliable AX) is the right tool. Phase 1's clipboard-mediated path coexists cleanly with that future AX-read path — neither throws away the other.
- **Latency budget unchanged.** Synthetic ⌘C + pasteboard round-trip ≈ 50ms; synthetic ⌘V + restore ≈ 150ms total. Both are inside the <500ms hotkey-to-first-token budget with room to spare.

## Edge cases to handle in Phase 1 implementation

- **Empty pasteboard after ⌘C** — user pressed hotkey without selection, or app blocked copy. Open panel empty; accept free-form prompt.
- **User switches apps mid-generation** — Localpen tracks frontmost app at hotkey time and re-activates it before paste. Minor focus flicker acceptable.
- **Selection lost between hotkey and accept** — ⌘V inserts at cursor instead of replacing. Same behavior as a human in that situation; acceptable.
- **Pasteboard contains non-string content** (image, file ref) when hotkey fires — save/restore all types, not just strings.
- **Synthetic ⌘C captured by global app** (e.g., password field, certain games) — pasteboard unchanged. Fall back to free-form prompt mode.
