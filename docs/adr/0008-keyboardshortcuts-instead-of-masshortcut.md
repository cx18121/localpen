# ADR 0008 — Use sindresorhus/KeyboardShortcuts instead of MASShortcut for the global hotkey

**Status:** Accepted
**Date:** 2026-05-24
**Supersedes:** SWIFTUI-SPEC §10 / §14 and PRD architecture line on MASShortcut.

## Context

Phase 1's global hotkey requirement (per [DESIGN.md §5.4](../../DESIGN.md) and [SWIFTUI-SPEC.md §10](../../SWIFTUI-SPEC.md)) needs a Swift library that registers a system-wide keyboard chord and fires a callback. The original spec named **`shpakovski/MASShortcut`** — long-standing, ObjC, "SPM-compatible, mature."

During M0 bootstrap, SPM resolution failed:

```
xcodebuild: error: Could not resolve package dependencies:
  the package manifest at '/Package.swift' cannot be accessed
```

Investigation: MASShortcut's only tagged release is `2.4.0` (2019). The repo's `Package.swift` was added on `master` after that tag was cut and never re-tagged. So any version-pinned SPM resolution (`from: 2.4.0`) fetches a working copy with no manifest. The available paths to keep MASShortcut were:

- `branch: master` — works, but pins to a moving ref. Every `xcodebuild -resolvePackageDependencies` could shift the dep without warning.
- `revision: <sha>` — works, but is a manual pin to an arbitrary commit. No semver story.
- Use a fork that has tagged SPM-compatible releases — adds a non-canonical dependency we'd have to vet.

None of those are clean.

## Decision

**Use [`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (`from: 2.0.0`) in place of MASShortcut.** Resolved to `2.4.0` at swap time.

Why it's the better fit:

1. **SPM-native from day one.** Tagged releases consistently ship `Package.swift`. No moving-branch trap.
2. **Actively maintained.** Active commits, frequent releases. MASShortcut's last tagged release is from 2019.
3. **SwiftUI-native chord recorder.** `KeyboardShortcuts.Recorder` is a `View`, not an `NSView`. Eliminates the `NSViewRepresentable` wrapper that SWIFTUI-SPEC §10.3 specified — net code reduction in M4.
4. **Swift-first API.** `KeyboardShortcuts.Name`-typed shortcuts and a `.onKeyDown(for:)` callback. No `NSKeyedArchiver`/UserDefaults dance that MASShortcut required for chord persistence.
5. **macOS 11+ requirement.** Compatible with our macOS 14 deployment target.

## Alternatives considered

1. **Pin MASShortcut to `branch: master`.** Works today. Rejected: unversioned dep is a hidden risk. A breaking change on `master` would surface as a silent build failure or, worse, runtime regression.
2. **Pin MASShortcut to a specific revision.** Stable, but each revision bump is a manual review with no semver guidance. Pointless ceremony for a foundational dep.
3. **Vendor MASShortcut into the repo.** Cuts the SPM dependency entirely. Rejected: takes on maintenance of a library we don't own and don't want to fork.
4. **Roll our own minimal hotkey wrapper around `Carbon.HIToolbox` / `RegisterEventHotKey`.** Possible in ~80 lines. Rejected: a chord recorder UI is non-trivial; reinventing it instead of pulling a vetted library is not a Phase 1 priority.

## Consequences

- **`HotkeyService.swift` rewrites against `KeyboardShortcuts.Name` + `KeyboardShortcuts.onKeyDown(for:)`.** Smaller than the MASShortcut version. No UserDefaults bridge needed — `KeyboardShortcuts` handles persistence itself, keyed by the `Name`.
- **`Settings/HotkeyRecorderView.swift` becomes a pure SwiftUI view** wrapping `KeyboardShortcuts.Recorder("Toggle Localpen:", name: .toggleLocalpen)`. SWIFTUI-SPEC §10.3's `NSViewRepresentable` wrapper is no longer needed.
- **`PanelError.hotkeyConflict` detection** uses `KeyboardShortcuts.System` conflict APIs (or simpler: surface failures via the recorder's built-in conflict UI). M6.4 narrows.
- **PRD, SWIFTUI-SPEC, PLAN, CLAUDE.md** all updated to reference KeyboardShortcuts instead of MASShortcut. Old MASShortcut names live on only in this ADR's history.
- **No code or design impact beyond the hotkey module.** Action set, panel anatomy, persistence schema, llama-server lifecycle — all unchanged.
- **Future risk:** sindresorhus libraries have moved to "feed-on-Patreon" advisory notices. Acceptable; the library is MIT-licensed and the API is small enough that a fork would be cheap if needed.
