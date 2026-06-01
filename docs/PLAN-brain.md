# Localpen Brain — Locked Build Plan

> Synthesis of Tracks A (integration map), B (brain layer), C (hub UI), D (KB reorg), from the `localpen-brain-foundation` design workflow, **reconciled with the 2026-06-01 grill decisions**. This is the contract build agents implement against. Verified against the live codebase 2026-06-01.

> **ADRs:** [0014](./adr/0014-brain-derived-fts5-index-over-vault.md) (brain = derived FTS5 index) · [0015](./adr/0015-autonomous-curation-discipline.md) (curation discipline) · [0016](./adr/0016-hub-surface-and-modes.md) (hub surface + modes).

---

## 0. LOCKED DECISIONS (grill, 2026-06-01)

The nine decisions the build obeys. Where they touched the synthesis below, the synthesis text has been corrected inline.

| # | Decision | Where it lands |
|---|----------|----------------|
| 1 | `cxkb` markdown = source of truth; `brain.sqlite` is a **disposable derived index** | Phases 1–2 (ADR 0014) |
| 2 | Writes split by **judgment**: additive → auto/no-gate; high-judgment → **queued one-click suggestions** | Phase 4 (ADR 0015) |
| 3 | **Fully local**; Qwen-7B for transforms, **~14B for curation** | Phase 4 (ADR 0015) |
| 4 | **Hybrid cadence**: per-conversation raw stash + **nightly dream cycle** (14B) synthesizes | Phase 4 (ADR 0015) |
| 5 | Transforms filable, but only via the dream cycle's **substance filter**; hot path files nothing | Phase 4 (ADR 0015) |
| 6 | Routing: selection→quick-action (unchanged); **no-selection→Hub** (opens on last mode, default Ask) | Phase 3 (ADR 0016); §2.9 corrected |
| 7 | Two **surfaces** (quick-action, hub); hub has **modes** (Ask/KB/People/Capture/Now); conversational surface = **Ask mode** | Phase 3 (ADR 0016) |
| 8 | People: Timeline appends **auto**; **new-person creation queued** | Phase 4 (ADR 0015); People mode read-only in Phase 3 |
| 9 | Agent access via **`localpen search` CLI** + `/cxkb-context` upgrade; **MCP deferred** | Phase 5 |

**Scope note:** Phases 1–3 below (the synthesis) build the **read path + hub UI + KB scaffold** — the foundation, and a complete, useful product on their own (brain-backed Ask + a navigable hub). Phases 4–5 (§7) add the **curation/write layer** and the **CLI** — they are designed here but build *after* the foundation proves out. Decisions 2/3/4/5 and the auto-population half of 8 belong to Phase 4; decision 9 to Phase 5.

---

## 1. ARCHITECTURE OVERVIEW

The brain is a **derived, rebuildable index of the Obsidian vault** (`~/Documents/cxkb`, ~88 md files) that rides into the existing ask pipeline through one additive prompt seam, plus a **navigable hub surface** that exposes the vault (and other modes) inside the existing notch panel. Three layers, cleanly separated:

1. **Index layer** (`brain.sqlite`, separate from `history.sqlite`): a `MarkdownParser` produces `KBPage` value types; `BrainIndex` keeps a contentless-external FTS5 table + a wikilink graph in lockstep; `KBWatcher` (FSEvents + debounce) drives incremental reindex; `KBSearch` ranks via bm25 + log-scaled backlink boost.
2. **Engine layer**: `ContextEngine.bundle(for:calendar:)` always includes `self/` + `now.md`, adds top-K query hits, caps to a token budget, and returns a `ContextBundle` whose `.text` slots into `AskContext.knowledge`. Gated by `BrainAccess.isActive` — **off ⇒ byte-identical to today's prompt**.
3. **UI layer**: one new `.hub` phase hosting a palette + mode-strip + per-mode body, reusing `MenuRow`/`SectionHeader`/`EmptyStateView`. KB/People/Capture/Now are mode views; Ask is reused verbatim. The calendar chip gets a structured-summary redesign (Option A).

```
  ~/Documents/cxkb (vault)                          history.sqlite (durable)
        │  FSEvents                                        │  v6: threads.context_knowledge
        ▼                                                  ▲
  ┌───────────┐  KBPage   ┌────────────┐                  │ (parallels context_calendar)
  │KBWatcher  │──────────▶│ BrainIndex │  brain.sqlite    │
  └───────────┘  debounce │ (FTS5+graph)│  (derived)      │
                          └─────┬──────┘                   │
                                │ rowid-join               │
                          ┌─────▼──────┐                   │
                          │  KBSearch  │ bm25+backlink      │
                          └─────┬──────┘                   │
                                ▼                           │
   calendar:String ──▶ ┌──────────────┐  ContextBundle     │
   (existing probe)    │ ContextEngine│───────────────────────────┐
                       └──────────────┘  .text             │      │
                                                            │      ▼
   HOTKEY ──▶ PanelController.captureAndShow ──▶ AskContext.knowledge ──▶ ActionPrompts.askUserMessage
                       │                                                   (<context> block, +1 line)
                       ▼
                 PanelView .hub ─▶ HubShell ─▶ {AskInput | KBModeView | PeopleModeView | CaptureModeView | NowModeView}
```

---

## 2. LOCKED SWIFT CONTRACTS

These are final. Where Track B and Track C disagreed, the resolution is stated.

### 2.1 Data models — `Localpen/Services/Brain/KBModels.swift`

```swift
enum KBPageType: String, Codable, Sendable {
    case journal, project, topic, source, self_ = "self", person, note, area, now
    init(frontmatter raw: String?) { self = raw.flatMap(KBPageType.init(rawValue:)) ?? .note }
}

struct KBPage: Sendable, Equatable {
    let path: String                 // absolute path, stable primary key
    let title: String                // filename without .md (== wikilink target form)
    let type: KBPageType
    let area: String                 // top-level folder under vault root
    let body: String                 // frontmatter-stripped markdown
    let outboundLinks: [String]      // normalized [[targets]], de-duped, in-order
    let tags: [String]
    let mtime: Date
    let frontmatter: [String: String]
}

struct ContextBundle: Sendable, Equatable {
    let text: String                 // multi-line, each line "kb [Title]: …" / "calendar: …"
    let sources: [Provenance]        // ordered, highest-relevance first
    let approxTokens: Int

    struct Provenance: Sendable, Equatable {
        let title: String
        let path: String
        let reason: Reason
        enum Reason: String, Sendable { case always, query, calendar }
    }
    static func calendarOnly(_ calendar: String?) -> ContextBundle  // brain-off path
}

struct BrainConfig: Sendable {
    var vaultRoot: URL
    var alwaysIncludeAreas: Set<String> = ["self"]
    var alwaysIncludeFiles: Set<String> = ["now.md"]      // included only if present
    var excludedDirComponents: Set<String> = [".obsidian", ".git", "raw"]
    var topK: Int = 6
    var maxContextTokens: Int = 1200
    var perPageCharCap: Int = 800
    static let `default`: BrainConfig
}

// PersonRecord / TimelineEntry: defined now, NOT on the v1 ask hot-path.
// Assembled on demand by ContextEngine.person(named:) for the future People mode.
struct PersonRecord: Sendable, Equatable {
    let name: String
    let frontmatter: [String: String]
    let compiledTruth: String        // v1 heuristic: page body or stitched backlink leads
    let timeline: [TimelineEntry]
}
struct TimelineEntry: Sendable, Equatable {
    let date: Date; let sourcePath: String; let snippet: String
}
```

### 2.2 `MarkdownParser.swift`

```swift
protocol MarkdownParsing: Sendable {
    func parse(url: URL, vaultRoot: URL) -> KBPage?
}
struct MarkdownParser: MarkdownParsing {
    func parse(url: URL, vaultRoot: URL) -> KBPage?
    // Pure statics, individually unit-testable:
    static func splitFrontmatter(_ raw: String) -> (frontmatter: [String: String], body: String)
    static func wikilinks(in body: String) -> [String]      // [[T]] / [[T|alias]] → "T", deduped
    static func isJournalName(_ title: String) -> Bool       // ^\d{4}-\d{2}-\d{2}$
    static func tags(_ raw: String?) -> [String]
    static func area(of url: URL, vaultRoot: URL) -> String
}
```

### 2.3 `BrainIndex.swift`

```swift
final class BrainIndex {
    init(config: BrainConfig = .default, parser: MarkdownParsing = MarkdownParser()) throws
    init(testInMemory: Bool, parser: MarkdownParsing = MarkdownParser()) throws  // mirrors Persistence

    var dbQueue: DatabaseQueue { get }                       // exposed for KBSearch injection

    func reindexAll(root: URL) async                         // full rebuild, mtime fast-path, prune
    func reindex(path: URL) async                            // incremental upsert (KBWatcher)
    func remove(path: URL) async

    // Read API for ContextEngine + future People mode:
    func alwaysPages(areas: Set<String>, files: Set<String>) async -> [KBPage]
    func pageByTitle(_ title: String) async -> KBPage?
    func backlinks(toTitle: String) async -> [KBPage]
    func recentPages(limit: Int) async -> [KBPage]           // for KB mode default landing

    static func migrate(_ queue: DatabaseQueue) throws       // v1.brain: pages, pages_fts, links, backlinks
}
```

Schema is locked to Track B §3.1 (tables `pages`, contentless-external `pages_fts(title,body,tags)`, `links`, `backlinks`). FTS sync is explicit in upsert/delete (no triggers).

### 2.4 `KBWatcher.swift`

```swift
final class KBWatcher: @unchecked Sendable {
    init(index: BrainIndex, config: BrainConfig = .default)
    func start()    // FSEventStream over [vaultRoot], FileEvents|UseCFTypes, private queue
    func stop()
    // Path filter (drop excluded dirs + non-.md) + 0.75s debounce/dedupe → index.reindex/remove
}
```

### 2.5 `KBSearch.swift`

```swift
struct KBHit: Sendable, Equatable { let page: KBPage; let score: Double }

final class KBSearch {
    init(dbQueue: DatabaseQueue)
    func search(_ query: String, limit: Int) async -> [KBHit]
    // Pure, unit-testable scoring — the single seam embeddings later extend:
    static func score(bm: Double, indegree: Int) -> Double   // -bm + 0.5*log2(1+indegree)
    static func sanitizeMatch(_ query: String) -> String     // FTS5 MATCH-safe (quote+OR-join)
}
```

### 2.6 `ContextEngine.swift`

```swift
final class ContextEngine {
    init(search: KBSearch, index: BrainIndex, config: BrainConfig = .default,
         isBrainEnabled: @escaping @Sendable () -> Bool = { BrainAccess.isActive })

    func bundle(for query: String, calendar: String?) async -> ContextBundle
    func person(named: String) async -> PersonRecord?        // future People mode; built when that lands

    static func condense(_ body: String, charCap: Int) -> String   // pure
    static func approxTokens(_ s: String) -> Int                    // chars/4
}
```

### 2.7 Ask-seam touch (additive — off ⇒ byte-identical)

```swift
// AskContext.swift — add ONE field + thread it through `from(_:)`
var knowledge: String?   // ContextBundle.text; chip shows "N notes" summary

// ActionPrompts.askUserMessage(question:context:) — add ONE line, before the `calendar:` line:
if let kb = context.knowledge { lines.append(kb) }   // kb lines are pre-prefixed "kb [Title]: …"
```

`ContextProbe.Snapshot` does **not** carry knowledge — the bundle is built in `PanelController` after capture (off-main, gated), then assigned to `askContext.knowledge`. Persistence: new nullable `threads.context_knowledge` (v6 on `history.sqlite`), stored via `createThreadForAsk(... contextKnowledge:)` and rehydrated in `loadSeedAskContext` — exactly mirroring `context_calendar`. **KB text stays on the thread, never on the interaction row** (preserves the calendar privacy boundary: out of interactions export + memory inference).

### 2.8 Brain enablement + access toggle

```swift
// Localpen/Services/BrainAccess.swift — mirrors CalendarAccess.isActive (UserDefaults-backed)
enum BrainAccess {
    static var isActive: Bool { get set }     // UserDefaults "brain.enabled"
    static var vaultRoot: URL { get set }      // overridable; defaults to ~/Documents/cxkb
}
```

### 2.9 Hub: enum-not-protocol (Track B vs C — **resolved: enum**)

Track C proposed an enum; Track A loosely referenced "the Mode protocol." **Locked: flat `HubMode` enum**, no protocol. Rationale (Track C §1.1, confirmed against code): modes are already an enum (`Phase`); the set is closed (5 modes); a protocol is a competing dispatch mechanism that violates Simplicity First. Mode views are independent files following a **convention** (`init(controller:)`, component-only rendering, no nav state), not a conformance.

```swift
// Localpen/Models/HubMode.swift
enum HubMode: String, CaseIterable, Identifiable {
    case ask, kb, people, capture, now
    var id: String { rawValue }
    var title: String        // "Ask","Knowledge","People","Capture","Now"
    var icon: String         // SF Symbols
    var keywords: [String]   // palette filter aliases
}

// PanelState.Phase: add `case hub` (renderKey 13)
// PanelController: new observed state
var hubMode: HubMode = .ask     // restored from UserDefaults last-used
var hubQuery: String = ""
var hubFocusedIndex: Int = 0
// + openHub(), setHubMode(_:), loadRecentNotes(), loadPeople(), loadNow(), commitCapture(_:)
// + `case .hub` in handleKeyDown
```

**No-selection routing (CORRECTED post-grill — see ADR 0016).** The synthesis draft kept "no-selection → `.ask` directly"; the **grill overrode this**: no-selection hotkey now routes to **`.hub`**, opened on its last-used mode (default `.ask`). So the common case still lands effectively in Ask — just inside the hub chrome, with the mode strip + palette visible. Selection hotkey still routes to `.captured` (quick-action, unchanged). The hub's Ask mode reuses the same `AskInput` verbatim. Net behavior: one keypress still gets you typing into Ask; the hub is the home, not a secondary screen.

### 2.10 Calendar chip — **Option A locked** (structured summary)

Track C §3.4 forked A vs B. **Locked: A.** The original complaint was specifically "a real summary instead of truncation"; the count *is* the summary. The formatter is already a pure, deterministic pass, so this is ~30 testable lines and respects the `CalendarEvent` boundary (ADR 0013). Prompt line untouched (display-only).

```swift
// Localpen/Services/CalendarSummary.swift
struct CalendarSummary: Sendable, Equatable {
    let todayCount: Int
    let nextTitle: String?
    let nextStart: Date?
    static func from(_ events: [ICSEvent], now: Date) -> CalendarSummary   // pure
}
// Threaded beside `calendar: String?` through ContextProbe.Snapshot + AskContext (display-only).
// CalendarChip (private view in AskInput.swift): accentTint fill, accentMute stroke,
// "calendar" SF Symbol in Tokens.accent, own full-width row. AskChip (app/selection) unchanged.
```

---

## 3. FILE PLAN

**Key finding:** `project.yml` globs sources by **directory path** (`- path: Localpen`) with `createIntermediateGroups: true`. New files under existing dirs (incl. new `Localpen/Services/Brain/` and `Localpen/Panel/Hub/`) are **auto-discovered** — `project.yml` does **NOT** need editing for new files, and is therefore **not a per-file serial bottleneck**. (Run `xcodegen generate` once after files land.)

### Phase 1 — Index core (pure + DB; no UI, no PanelController)
| File | C/M | Purpose |
|---|---|---|
| `Localpen/Services/Brain/KBModels.swift` | C | Value types: KBPage, ContextBundle, BrainConfig, PersonRecord, KBPageType |
| `Localpen/Services/Brain/MarkdownParser.swift` | C | Frontmatter + wikilink extraction, no dependency, pure statics |
| `Localpen/Services/Brain/BrainIndex.swift` | C | FTS5 + wikilink-graph index; reindexAll/reindex/remove; brain.sqlite migrator |
| `Localpen/Services/Brain/KBSearch.swift` | C | bm25 + log-backlink ranking; pure `score(bm:indegree:)` |
| `Localpen/Services/BrainAccess.swift` | C | UserDefaults enable toggle + vault root |
| `LocalpenTests/MarkdownParserTests.swift` | C | Parse real vault files; journal override; wikilink dedupe |
| `LocalpenTests/BrainIndexTests.swift` | C | testInMemory: upsert/delete FTS lockstep; backlink in-degree; prune |
| `LocalpenTests/KBSearchTests.swift` | C | `score` purity; hub page doesn't outrank exact-title match |

### Phase 2 — Engine + watcher + ask-seam wiring (depends on Phase 1)
| File | C/M | Purpose |
|---|---|---|
| `Localpen/Services/Brain/ContextEngine.swift` | C | Bundle assembly, always-pages, budget cap |
| `Localpen/Services/Brain/KBWatcher.swift` | C | FSEvents → debounced incremental reindex |
| `Localpen/Services/CalendarSummary.swift` | C | Structured calendar summary (Option A), pure compute |
| `Localpen/Models/AskContext.swift` | **M (serial)** | Add `knowledge` field + `CalendarSummary`; thread through `from(_:)` |
| `Localpen/Models/ActionPrompts.swift` | **M (serial)** | Add one `if let kb` line in `askUserMessage` |
| `Localpen/Services/ContextProbe.swift` | **M (serial)** | Carry `CalendarSummary` beside `calendar` in Snapshot |
| `Localpen/Services/ICSCalendarReader.swift` | M | Also return structured summary in the existing pure pass |
| `Localpen/Services/Persistence.swift` | **M (serial)** | v6 migration: `threads.context_knowledge` |
| `Localpen/Services/ConversationStore.swift` | **M (serial)** | `createThreadForAsk(... contextKnowledge:)` + `loadSeedAskContext` read |
| `LocalpenTests/ContextEngineTests.swift` | C | self/ survives budget; brain-off == brain-never-existed prompt |
| `LocalpenTests/CalendarSummaryTests.swift` | C | count/next-event correctness |

### Phase 3 — Hub UI (depends on Phase 2 engine + store loaders)
| File | C/M | Purpose |
|---|---|---|
| `Localpen/Models/HubMode.swift` | C | HubMode enum (id/title/icon/keywords) |
| `Localpen/Panel/Hub/HubShell.swift` | C | Shell: palette + strip + body dispatch + footer |
| `Localpen/Panel/Hub/HubPalette.swift` | C | Rail-input filter bound to `hubQuery` |
| `Localpen/Panel/Hub/HubModeStrip.swift` | C | 5 mode tiles, active = accentTint+rail |
| `Localpen/Panel/Hub/KBModeView.swift` | C | KB list/search via SectionHeader/MenuRow/EmptyStateView |
| `Localpen/Panel/Hub/PeopleModeView.swift` | C | People browse (PersonRecord); same vocabulary |
| `Localpen/Panel/Hub/CaptureModeView.swift` | C | Quick text → `raw/inbox/`; rail input + OutlineButton |
| `Localpen/Panel/Hub/NowModeView.swift` | C | View/edit `now.md`; Card + rail editor |
| `Localpen/Models/PanelState.swift` | **M (serial)** | Add `case hub` + renderKey 13 |
| `Localpen/Panel/PanelView.swift` | **M (serial)** | Add `case .hub: HubShell(controller:)` |
| `Localpen/Panel/AskInput.swift` | **M (serial)** | Replace calendar branch with `CalendarChip`; add private view |
| `Localpen/Panel/PanelController.swift` | **M (serial — HOTSPOT)** | hub state + openHub/setHubMode + mode loaders + ContextEngine wiring in startAskStream + `case .hub` keys |

**Shared serial integration points (edit one-at-a-time, never parallel):**
`PanelController.swift` (touched in Phase 2 ask-seam AND Phase 3 hub — the single hottest file), `AskContext.swift`, `ActionPrompts.swift`, `ContextProbe.swift`, `Persistence.swift`, `ConversationStore.swift`, `PanelState.swift`, `PanelView.swift`, `AskInput.swift`. `project.yml` is **not** in this list for new files (auto-globbed); only run `xcodegen generate` once per phase after new files land.

---

## 4. BUILD DAG

```
PHASE 1 (parallel — pure/DB, zero shared-file contention)
  ┌─ A1: KBModels.swift ──────────────┐ (no deps; blocks everything)
  │                                    ▼
  ├─ A2: MarkdownParser + tests ───────┤  (needs KBModels)
  ├─ A3: BrainIndex + migrator + tests ┤  (needs KBModels + MarkdownParsing protocol)
  ├─ A4: KBSearch + tests ─────────────┤  (needs KBModels + BrainIndex.dbQueue shape)
  └─ A5: BrainAccess.swift ────────────┘  (independent)
  SERIAL GATE: xcodegen generate → build → all Phase-1 tests green.

PHASE 2 (engine + seam; some parallel, the seam edits are SERIAL)
  parallel:
    ├─ B1: ContextEngine + tests        (needs A3,A4)
    ├─ B2: KBWatcher                    (needs A3)
    └─ B3: CalendarSummary + tests      (independent of brain)
  SERIAL chain (one agent, ordered — all touch shared model/store files):
    B4: ICSCalendarReader + ContextProbe + AskContext  (carry CalendarSummary)
      → B5: Persistence v6 + ConversationStore (context_knowledge)
      → B6: ActionPrompts askUserMessage (+1 line)
      → B7: PanelController.startAskStream wiring (build bundle off-main, gate on BrainAccess,
             assign askContext.knowledge, persist via createThreadForAsk)
  SERIAL GATE: xcodegen generate → build → ask tests green (incl. brain-off byte-identical).
  DEPENDENCY: B4–B7 block Phase 3 (hub reuses AskInput + the wired controller).

PHASE 3 (hub UI; mode views parallel, the dispatch/state edits SERIAL)
  parallel (independent files, each init(controller:)):
    ├─ C1: HubMode.swift
    ├─ C2: KBModeView      (needs BrainIndex.recentPages via controller loader)
    ├─ C3: PeopleModeView  (needs ContextEngine.person)
    ├─ C4: CaptureModeView
    ├─ C5: NowModeView
    ├─ C6: HubPalette / HubModeStrip / HubFooter
  SERIAL chain (one agent — shared dispatch/state files + PanelController HOTSPOT):
    C7: PanelState .hub + renderKey
      → C8: PanelController hub state + openHub/setHubMode + mode loaders + case .hub keys
      → C9: HubShell dispatch + PanelView .hub case
      → C10: AskInput CalendarChip swap (depends on B4's CalendarSummary)
  SERIAL GATE: xcodegen generate → build → manual visual check (hand to user; no scripted hotkey).
```

**Critical-path blockers:** A1 blocks all of Phase 1. B4→B7 serial chain blocks Phase 3 start. `PanelController.swift` is edited in both B7 and C8 — these must not overlap (same agent or strictly sequential). KB reorg (§5) is **independent of all code** and can run any time (it only changes vault content the index reads at runtime).

---

## 5. KB REORG SUMMARY

**Verdict: additive, not relocating.** "Pango" and named people don't exist in the vault yet, and every current `projects/` page is a side-project — so the reorg creates new scaffolding (`areas/`, `people/`, `now.md`, schema) with **zero file relocations** and a handful of light cross-link edits.

```
cxkb/
├── CLAUDE.md          TOUCH (schema — DISCUSS-FIRST gate)
├── index.md           TOUCH (add Areas/People sections, link now.md)
├── log.md             TOUCH (append restructure entry)
├── now.md             CREATE (vault-root live "this week" entry point)
├── raw/ sources/ topics/ projects/ journal/ self/   UNCHANGED
├── areas/             CREATE  pango/{README,meetings/,work-projects/}  school/README  creative/README
└── people/            CREATE  .gitkeep only (template lives in CLAUDE.md, per vault convention)
```

**Counts:** 0 moves · 0 splits · ~6 creates (`now.md` + 4 area READMEs + `people/.gitkeep`) · 4 touches (`CLAUDE.md`, `index.md`, `log.md`, `self/Current Focus.md` ~3-line connection edit).

**Discuss-first gates (hard, before writing):**
1. **`CLAUDE.md` schema edits** (§4 of Track D) — vault trigger #5, the one hard gate.
2. **Creating new top-level `areas/`** — recommended discuss-first by analogy to topic promotion.
Everything else is routine diff-as-review. Commit sequence: (1) `feat(schema): document areas/, people/, now.md`; (2) `feat: scaffold areas/ + people/ + now.md`. Explicit `git add <paths>` only — never `git add -A`.

**`now.md` ↔ `Current Focus.md`:** `now.md` = live/weekly foreground; `Current Focus.md` = stable/monthly background. Link, don't duplicate; persistent `now.md` items graduate into `Current Focus`.

### Full file-by-file table

| Page(s) | Decision | Detail |
|---|---|---|
| `CLAUDE.md` | TOUCH (DISCUSS-FIRST) | Add areas/people/now.md sections + person/area templates |
| `index.md` | TOUCH | Add `## Areas`, `## People`; link `now.md` |
| `log.md` | TOUCH | Append `[2026-06-01] restructure` entry |
| `now.md` | CREATE | Live weekly entry point (template in Track D §4a) |
| `self/About.md` | KEEP | Identity stays; optional connection line |
| `self/Current Focus.md` | KEEP + ~3-line edit | Reciprocal link to `now.md`; redefine as background doc |
| `self/Working Style.md` | KEEP | Pure identity |
| `journal/2026-05-11.md`, `2026-05-12.md` | KEEP | Date-stamped; areas pull via wikilink, not move |
| All 24 `projects/*.md` | KEEP | All side-projects; moving breaks ~40 inbound links |
| All 9 `topics/*.md` | KEEP | Cross-cutting hubs, orthogonal to areas/people |
| All 13 `sources/*.md` | KEEP | 1:1 with raw/, unaffected |
| `raw/**` | UNCHANGED | Immutable |
| `areas/pango/{README,meetings/,work-projects/}` | CREATE | Empty scaffolding + README hub (no fabricated content) |
| `areas/school/README.md`, `areas/creative/README.md` | CREATE | Area hubs (template §4c) |
| `people/.gitkeep` | CREATE | Scaffolding; template in CLAUDE.md, no person pages until real names supplied |

---

## 6. OPEN DECISIONS

Only genuine forks needing your call before/at build:

1. **Hub mode-jump chord** — `⌃⌥1…5`, or none? (⌘-digits collide with source apps.) Recommend `⌃⌥` or omit. *Non-blocking — defaults to omit if unanswered.*
2. **Mode-strip overflow at 400pt** — 5 icon+label tiles likely won't fit. Needs a design rhythm decision: icon-only with label on active tile, or tighter tiles. *Blocks Phase 3 C6 (HubModeStrip) only; recommend icon-only + active-label as the default if unanswered.*
3. **KB reorg `CLAUDE.md` schema edits + new top-level areas** — both discuss-first gated; need explicit approval before writing vault files. *Blocks the KB reorg commit, not the code.*
4. **Real people to seed** `people/` — none found in the vault. If you have Pango teammates / recruiters / mentors, supply names; otherwise `people/` ships as scaffolding only.

Everything else (separate `brain.sqlite`, FTS5-now/embeddings-later seam, enum-not-protocol, Option-A calendar chip, additive-not-relocating reorg, off ⇒ byte-identical prompt) is locked and safe to build.

**Resolved at grill (no longer open):** the agent-retrieval interface — **CLI, not MCP** (decision #9, §7 Phase 5). MCP deferred until a non-Claude-Code client genuinely needs it.

---

## 7. CURATION & CLI LAYER (Phases 4–5 — designed, builds after the foundation)

The synthesis (§§1–6) is the read path + hub + KB scaffold. These phases add the write/curation layer (ADR 0015) and the agent CLI (decision #9). They depend on Phase 2 (the ContextEngine + the conversation store) and Phase 3 (a suggestion-surfacing UI home). Design is locked; sequencing is *after* the foundation ships and proves out.

### Phase 4 — Autonomous curation (ADR 0015)

**Model strategy.** Add a second local model: keep Qwen-7B for the latency-critical quick-action transforms; download a **~14B instruct model** for curation. Model management follows ADR 0005 (model-agnostic). The 14B is loaded only for the nightly cycle (and on-demand high-judgment suggestions), not kept warm.

**Write classifier — the core rule.** Every candidate write is classified:
- **Additive / structured → auto-apply, no gate, git-backed.** Capture → `raw/inbox/<ts>.md`; append a Timeline entry to an *existing* `people/` page; create a `sources/` page from template; nominate dangling `[[links]]`; update `now.md`. These reuse the vault's diff-as-review-then-commit flow with explicit `git add <paths>` (never `-A`).
- **High-judgment → queued suggestion, never silent.** Rewrite a curated page; promote a topic; resolve a contradiction; **create a new person / merge identities**. Surfaced as a one-click proposal in the hub (a `Suggestions` affordance — likely a Now-mode or People-mode inbox), apply or dismiss, or hand the page to a Claude Code session.

**Cadence — hybrid.**
- *Hot path (per conversation):* `ConversationStash` writes the raw transcript instantly to a stash area (cheap, no model, no latency). Eligible: Ask/conversational threads only — quick-action transforms are *not* stashed here.
- *Nightly dream cycle:* a scheduled `DreamCycle` job (the menu-bar app is always alive; a coalescing timer fires it off-peak) runs the 14B over (a) the day's stashed conversations and (b) `raw/inbox/`. It distills additive writes, enqueues high-judgment suggestions, and applies a **substance filter** so trivial transforms/throwaway asks never get filed.

**People population** inherits the classifier: Timeline append to an existing person = additive/auto; new-person creation or identity merge = queued. Seed signal = conversation mentions (primary) + manual; calendar attendees only if present in the feed (unreliable — don't depend on it).

**New files (indicative):** `Localpen/Services/Brain/ConversationStash.swift`, `DreamCycle.swift`, `WriteClassifier.swift` (pure, unit-tested), `VaultWriter.swift` (markdown + git, explicit-path commits), `CurationModel.swift` (14B loader); a `Suggestions` store + hub affordance; tests on the pure classifier + substance filter + the additive-write/git path.

**Risks to design against:** 14B synthesis quality on the substance filter (false-file vs miss); git-commit hygiene from an automated writer (must honor `cxkb/CLAUDE.md`: explicit paths, no `-A`, atomic per-item); the dream cycle must be cancellable/idempotent (re-running a day mustn't double-file — hash/dedupe like the calendar cache).

### Phase 5 — Agent retrieval CLI (decision #9)

A small **`localpen search "<query>"`** command (and `localpen get <title>`, `localpen backlinks <title>`) over the **same `KBSearch` core** as the GUI, querying `brain.sqlite` directly so it works **without the GUI focused/running** (as long as the index file exists; if stale, it triggers a reindex). Emits ranked results (text, `--json` option).

Then **upgrade `/cxkb-context`** (global skill at `~/.claude/skills/cxkb-context/`) to shell out to `localpen search` instead of the "read `index.md` then drill" approach the vault's own manual flagged as non-scaling. One ranked-retrieval source for both the GUI and Claude Code.

**MCP deferred:** `localpen serve` (stdio MCP wrapping the same core) is an afternoon's work to add *if* a non-Claude-Code client (Cursor, ChatGPT, Claude Desktop) ever needs the brain. Not built on spec.

**New files (indicative):** a CLI entry target / argument-parsing front-end over `KBSearch` + `BrainIndex` (sharing the module, not duplicating the query logic); the skill edit lives in the user's `~/.claude/skills/`, outside this repo.

### Updated build order (full picture)

```
Phase 1  Index core (pure + DB)                     ─┐
Phase 2  Engine + watcher + ask-seam (serial wiring) ─┼─ FOUNDATION (brain-backed Ask + hub)
Phase 3  Hub UI (modes; calendar chip; no-sel→hub)  ─┘   ← ships + proves out first
Phase 4  Curation: 14B + dream cycle + write classifier + suggestions   ← after foundation
Phase 5  `localpen search` CLI + /cxkb-context upgrade (MCP deferred)
+  KB reorg (markdown) — independent of all code; can run any time (gated only by the
   two discuss-first approvals: CLAUDE.md schema edit + new top-level areas/).
```
