# Brain-Grounded Writing — Foundation (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the three user-steered actions (respond / custom / ask) pull paragraph-precise context about the people/projects you name, grounded in your notes — typing `[[Ana]]` in an instruction produces a draft informed by Ana's page, in your voice.

**Architecture:** A chunk-level embedding layer (`Chunker` → `page_chunks` → `ChunkStore`, backfilled alongside the existing page embeddings) sits under a mention-aware retrieval seam. `MentionResolver` (pure) detects `[[name]]`/`@name` + auto-matches against people/project titles; `MentionGrounding` (pure) ranks an entity's chunks against the draft and formats a header. `ContextEngine.bundle` prioritizes resolved-mention pages in the token budget, then wires into `runStream` (respond/custom) and `startAskStream` (ask). UI for first-class mention input is **Plan B**, separate.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), XCTest, llama.cpp (EmbeddingGemma-300m via the existing `EmbeddingService`).

## Global Constraints

- macOS deployment target **14 (Sonoma)** minimum.
- Embedding model **EmbeddingGemma-300m**, **dim 256** (`EmbeddingService.modelID`, `EmbeddingService.dim`). Do not change.
- Brain is optional: every failure path (brain off, embedding server down, page unembedded) must degrade to **byte-identical** pre-W2 prompt output. Brain-off ⇒ `ContextBundle.empty`.
- Grounding applies **only** to `respond` / `custom` / `ask` — never the 6 fixed quick-actions.
- Chunks serve mention grounding **only**; the page-level `KBSearch.hybridSearch` ask path and its recall gate are untouched.
- No new SPM dependency. No new model. No new hotkey.
- Test fixtures trace to real cxkb page shapes (frontmatter + markdown body) — never invented payloads.
- TDD: failing test → minimal impl → green → commit. One logical change per commit.

---

### Task 1: `Chunker` — split a page body into heading-respecting chunks

**Files:**
- Create: `Localpen/Services/Brain/Chunker.swift`
- Test: `LocalpenTests/ChunkerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct Chunk: Sendable, Equatable {
      let heading: String?   // nearest preceding markdown heading text (markers stripped); nil if none
      let text: String       // chunk body, heading line excluded, trimmed
  }
  enum Chunker {
      /// Split `body` (frontmatter-stripped markdown) into chunks. Chunks never span a
      /// heading boundary; a section longer than `maxChars` is split on paragraph/space;
      /// a trailing chunk shorter than `minChars` merges into the previous same-heading chunk.
      static func chunk(_ body: String, targetChars: Int = 512, maxChars: Int = 1000, minChars: Int = 120) -> [Chunk]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class ChunkerTests: XCTestCase {
    func test_singleShortParagraph_isOneChunkNoHeading() {
        let out = Chunker.chunk("Ana runs the launch. She prefers terse updates.")
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].heading)
        XCTAssertEqual(out[0].text, "Ana runs the launch. She prefers terse updates.")
    }

    func test_headingsBecomeChunkBoundaries_andHeadingIsCaptured() {
        let body = "## Background\nMet at Cornell.\n\n## Launch\nShe owns the Q3 launch."
        let out = Chunker.chunk(body)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].heading, "Background")
        XCTAssertEqual(out[0].text, "Met at Cornell.")
        XCTAssertEqual(out[1].heading, "Launch")
        XCTAssertEqual(out[1].text, "She owns the Q3 launch.")
    }

    func test_longSectionSplitsAtMaxChars() {
        let para = String(repeating: "word ", count: 300)   // ~1500 chars, one paragraph
        let out = Chunker.chunk("# H\n\(para)", targetChars: 512, maxChars: 1000, minChars: 120)
        XCTAssertGreaterThanOrEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.text.count <= 1000 })
        XCTAssertTrue(out.allSatisfy { $0.heading == "H" })
    }

    func test_trailingRuntMergesIntoPreviousSameHeadingChunk() {
        // Two paragraphs under one heading: a big one (> target) then a tiny runt.
        let big = String(repeating: "alpha ", count: 100)   // ~600 chars
        let body = "# H\n\(big)\n\ntiny."
        let out = Chunker.chunk(body, targetChars: 512, maxChars: 1000, minChars: 120)
        XCTAssertEqual(out.count, 1, "the sub-minChars runt merges back rather than standing alone")
        XCTAssertTrue(out[0].text.hasSuffix("tiny."))
    }

    func test_emptyBody_isNoChunks() {
        XCTAssertEqual(Chunker.chunk("   \n\n  "), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ChunkerTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'Chunker' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Splits a frontmatter-stripped markdown body into heading-respecting chunks for
/// chunk-level embedding (W2 grounding). Pure + total so it's unit-testable with no I/O.
/// Chunks never span a heading; an over-long section is split on paragraph/whitespace;
/// a trailing runt merges back so grounding never surfaces a 3-word fragment.
struct Chunk: Sendable, Equatable {
    let heading: String?
    let text: String
}

enum Chunker {
    static func chunk(_ body: String, targetChars: Int = 512, maxChars: Int = 1000, minChars: Int = 120) -> [Chunk] {
        let lines = body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")

        // 1. Group lines into (heading, [paragraph]) sections. A heading line opens a section.
        var sections: [(heading: String?, paragraphs: [String])] = []
        var curHeading: String? = nil
        var curParas: [String] = []
        var buf: [String] = []
        func flushPara() {
            let p = buf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { curParas.append(p) }
            buf = []
        }
        func flushSection() {
            flushPara()
            if !curParas.isEmpty { sections.append((curHeading, curParas)) }
            curParas = []
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.first == "#" {
                flushSection()
                curHeading = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if t.isEmpty {
                flushPara()
            } else {
                buf.append(t)
            }
        }
        flushSection()

        // 2. Within each section, pack paragraphs to ~target, hard-split > maxChars, merge runts.
        var chunks: [Chunk] = []
        for (heading, paras) in sections {
            var packed: [String] = []
            var cur = ""
            func push() { if !cur.isEmpty { packed.append(cur); cur = "" } }
            for para in paras {
                for piece in Self.hardSplit(para, maxChars: maxChars) {
                    if cur.isEmpty { cur = piece }
                    else if cur.count + 1 + piece.count <= targetChars { cur += " " + piece }
                    else { push(); cur = piece }
                }
            }
            push()
            // Merge a trailing runt into its predecessor (same heading only).
            if packed.count >= 2, let last = packed.last, last.count < minChars {
                packed[packed.count - 2] += " " + last
                packed.removeLast()
            }
            chunks.append(contentsOf: packed.map { Chunk(heading: heading, text: $0) })
        }
        return chunks
    }

    /// Split a single paragraph that exceeds `maxChars` on word boundaries; short paragraphs
    /// pass through unchanged.
    private static func hardSplit(_ para: String, maxChars: Int) -> [String] {
        guard para.count > maxChars else { return [para] }
        var out: [String] = []
        var cur = ""
        for word in para.split(separator: " ") {
            if cur.isEmpty { cur = String(word) }
            else if cur.count + 1 + word.count <= maxChars { cur += " " + word }
            else { out.append(cur); cur = String(word) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ChunkerTests 2>&1 | tail -20`
Expected: PASS — `Executed 5 tests, with 0 failures`.

> Note: `ChunkerTests.swift` and `Chunker.swift` are new files. `Localpen.xcodeproj/project.pbxproj` is gitignored — Xcode adds new files to its own working copy automatically; verify the test build picks them up (it will if you opened/built in Xcode or the file-system-synchronized membership is active). If `cannot find type` appears for a file that exists, the file isn't in the target — add it via Xcode.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Chunker.swift LocalpenTests/ChunkerTests.swift
git commit -m "feat(brain): Chunker — heading-respecting page chunking for W2 grounding"
```

---

### Task 2: `page_chunks` table + `ChunkStore`

**Files:**
- Modify: `Localpen/Services/Brain/BrainIndex.swift` (add migration `v4.page_chunks` inside `migrate(_:)`, after the `v3.embedding_mtime` migration block)
- Create: `Localpen/Services/Brain/ChunkStore.swift`
- Test: `LocalpenTests/ChunkStoreTests.swift`

**Interfaces:**
- Consumes: `VectorMath.data(from:)`, `VectorMath.floats(from:)`, `BrainIndex(testInMemory:)`, `index.dbQueue`.
- Produces:
  ```swift
  struct ChunkStore {
      let dbQueue: DatabaseQueue
      struct Insert: Equatable { let index: Int; let heading: String?; let text: String; let vector: [Float] }
      struct ChunkRow: Equatable { let path: String; let index: Int; let heading: String?; let text: String; let vector: [Float] }
      /// Replace all chunks for a path (delete-then-insert) so a re-chunk handles count changes.
      func replace(path: String, chunks: [Insert], model: String, mtime: Double) async throws
      /// Chunks for the given paths, ordered by (path, index). Empty paths ⇒ [].
      func loadChunks(forPaths paths: [String]) async throws -> [ChunkRow]
      /// Pages needing (re)chunking: never chunked OR chunked against an older page mtime.
      func staleOrUnchunkedPaths() async throws -> [String]
  }
  ```

- [ ] **Step 1: Add the migration**

In `BrainIndex.migrate(_:)`, immediately after the `m.registerMigration("v3.embedding_mtime")` block and before `try m.migrate(queue)`:

```swift
        m.registerMigration("v4.page_chunks") { db in
            // Chunk-level embeddings for W2 mention grounding (paragraph-precise). Parallel
            // to page_embeddings, which is kept intact for the page-level ask path. `text` is
            // stored so grounding emits a snippet without re-reading the file; `mtime` is the
            // page mtime the chunks were computed from (drives staleness like page_embeddings).
            try db.create(table: "page_chunks") { t in
                t.column("path", .text).notNull()
                    .references("pages", column: "path", onDelete: .cascade)
                t.column("chunk_index", .integer).notNull()
                t.column("heading", .text)
                t.column("text", .text).notNull()
                t.column("vector", .blob).notNull()
                t.column("dim", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("mtime", .double).notNull().defaults(to: 0)
                t.primaryKey(["path", "chunk_index"])
            }
        }
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import GRDB
@testable import Localpen

final class ChunkStoreTests: XCTestCase {
    private func makeIndexWithPage(mtime: Double = 0) async throws -> BrainIndex {
        let index = try BrainIndex(testInMemory: true)
        try await index.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pages(path,title,type,area,body,tags,mtime,frontmatter_json)
                VALUES('/v/ana.md','Ana','person','people','body','',\(mtime),'{}')
                """)
        }
        return index
    }

    func test_replaceAndLoad_roundTripsChunks() async throws {
        let index = try await makeIndexWithPage()
        let store = ChunkStore(dbQueue: index.dbQueue)
        try await store.replace(path: "/v/ana.md", chunks: [
            .init(index: 0, heading: "Launch", text: "owns Q3 launch", vector: [0.1, 0.2, 0.3]),
            .init(index: 1, heading: nil, text: "prefers terse updates", vector: [0.4, 0.5, 0.6]),
        ], model: "embeddinggemma-300m", mtime: 0)

        let rows = try await store.loadChunks(forPaths: ["/v/ana.md"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].heading, "Launch")
        XCTAssertEqual(rows[0].text, "owns Q3 launch")
        XCTAssertEqual(rows[0].vector, [0.1, 0.2, 0.3])
        XCTAssertEqual(rows[1].heading, nil)
    }

    func test_replace_isDeleteThenInsert() async throws {
        let index = try await makeIndexWithPage()
        let store = ChunkStore(dbQueue: index.dbQueue)
        try await store.replace(path: "/v/ana.md", chunks: [
            .init(index: 0, heading: nil, text: "a", vector: [1]),
            .init(index: 1, heading: nil, text: "b", vector: [1]),
        ], model: "m", mtime: 0)
        try await store.replace(path: "/v/ana.md", chunks: [
            .init(index: 0, heading: nil, text: "only", vector: [1]),
        ], model: "m", mtime: 0)
        let rows = try await store.loadChunks(forPaths: ["/v/ana.md"])
        XCTAssertEqual(rows.map(\.text), ["only"], "re-chunk replaces, never appends")
    }

    func test_loadChunks_emptyPaths_returnsEmpty() async throws {
        let index = try await makeIndexWithPage()
        let store = ChunkStore(dbQueue: index.dbQueue)
        let rows = try await store.loadChunks(forPaths: [])
        XCTAssertEqual(rows, [])
    }

    func test_staleOrUnchunked_flagsUnchunkedAndStale() async throws {
        let index = try await makeIndexWithPage(mtime: 100)
        let store = ChunkStore(dbQueue: index.dbQueue)
        // Unchunked → stale.
        var stale = try await store.staleOrUnchunkedPaths()
        XCTAssertEqual(stale, ["/v/ana.md"])
        // Chunk at the page mtime → no longer stale.
        try await store.replace(path: "/v/ana.md",
            chunks: [.init(index: 0, heading: nil, text: "x", vector: [1])], model: "m", mtime: 100)
        stale = try await store.staleOrUnchunkedPaths()
        XCTAssertEqual(stale, [])
        // Bump page mtime (simulate edit) → stale again.
        try await index.dbQueue.write { db in
            try db.execute(sql: "UPDATE pages SET mtime = 200 WHERE path = '/v/ana.md'")
        }
        stale = try await store.staleOrUnchunkedPaths()
        XCTAssertEqual(stale, ["/v/ana.md"])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ChunkStoreTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'ChunkStore' in scope".

- [ ] **Step 4: Write `ChunkStore`**

```swift
import Foundation
import GRDB

/// Read/write chunk-level vectors in `brain.sqlite` (`page_chunks`, ADR 0014 extension for
/// W2). Mirrors `EmbeddingStore` but per-chunk and scoped: `loadChunks(forPaths:)` pulls only
/// the handful of pages a mention touches, never the whole vault. Vectors are BLOBs (no
/// sqlite-vec); cosine is brute-force at the scoped count.
struct ChunkStore {
    let dbQueue: DatabaseQueue

    struct Insert: Equatable { let index: Int; let heading: String?; let text: String; let vector: [Float] }
    struct ChunkRow: Equatable { let path: String; let index: Int; let heading: String?; let text: String; let vector: [Float] }

    func replace(path: String, chunks: [Insert], model: String, mtime: Double) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM page_chunks WHERE path = ?", arguments: [path])
            for c in chunks {
                try db.execute(sql: """
                    INSERT INTO page_chunks(path, chunk_index, heading, text, vector, dim, model, mtime)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, arguments: [path, c.index, c.heading, c.text,
                                     VectorMath.data(from: c.vector), c.vector.count, model, mtime])
            }
        }
    }

    func loadChunks(forPaths paths: [String]) async throws -> [ChunkRow] {
        guard !paths.isEmpty else { return [] }
        return try await dbQueue.read { db in
            let qs = paths.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: """
                SELECT path, chunk_index, heading, text, vector FROM page_chunks
                WHERE path IN (\(qs)) ORDER BY path, chunk_index
                """, arguments: StatementArguments(paths)).map { row in
                ChunkRow(path: row["path"], index: row["chunk_index"], heading: row["heading"],
                         text: row["text"], vector: VectorMath.floats(from: row["vector"] as Data))
            }
        }
    }

    func staleOrUnchunkedPaths() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.path FROM pages p
                LEFT JOIN page_chunks c ON c.path = p.path
                GROUP BY p.path
                HAVING COUNT(c.path) = 0 OR MAX(c.mtime) <> p.mtime
                """)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ChunkStoreTests 2>&1 | tail -20`
Expected: PASS — `Executed 4 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Localpen/Services/Brain/BrainIndex.swift Localpen/Services/Brain/ChunkStore.swift LocalpenTests/ChunkStoreTests.swift
git commit -m "feat(brain): page_chunks table + ChunkStore (scoped chunk vectors)"
```

---

### Task 3: Chunk backfill — embed chunks alongside page embeddings

**Files:**
- Modify: `Localpen/Services/Brain/BrainIndex.swift` (add `backfillChunks`, near `backfillEmbeddings`)
- Modify: `Localpen/AppDelegate.swift:226` (call it after `backfillEmbeddings`)
- Test: `LocalpenTests/BrainIndexTests.swift` (add one chunk-backfill test using a fake embedder)

**Interfaces:**
- Consumes: `Chunker.chunk(_:)`, `ChunkStore.replace(...)`, `ChunkStore.staleOrUnchunkedPaths()`, `EmbeddingService.embed(_:kind:)`, `EmbeddingService.modelID`.
- Produces: `func backfillChunks(service: EmbeddingService, store: ChunkStore) async`

- [ ] **Step 1: Add `backfillChunks` to `BrainIndex`**

Place directly below `backfillEmbeddings(service:store:)`:

```swift
    /// Re-chunk + re-embed every stale/unchunked page (W2 grounding). Best-effort and
    /// idempotent: a down embedding server or a page that fails to embed is skipped, leaving
    /// it stale for the next backfill. Runs after `backfillEmbeddings` at startup.
    func backfillChunks(service: EmbeddingService, store: ChunkStore) async {
        guard let paths = try? await store.staleOrUnchunkedPaths() else { return }
        for path in paths {
            guard let row = try? await dbQueue.read({ db in
                try Row.fetchOne(db, sql: "SELECT body, mtime FROM pages WHERE path = ?", arguments: [path])
            }) ?? nil else { continue }
            let body = row["body"] as String? ?? ""
            let mtime = row["mtime"] as Double? ?? 0
            var inserts: [ChunkStore.Insert] = []
            for (i, ch) in Chunker.chunk(body).enumerated() {
                guard let vec = try? await service.embed(ch.text, kind: .document) else { continue }
                inserts.append(.init(index: i, heading: ch.heading, text: ch.text, vector: vec))
            }
            // Even an empty page gets a `replace` (clears stale chunks); a partial-embed page
            // stays stale because its stored mtime won't match until all chunks land.
            try? await store.replace(path: path, chunks: inserts,
                                     model: EmbeddingService.modelID,
                                     mtime: inserts.isEmpty ? -1 : mtime)
        }
    }
```

> The `mtime: inserts.isEmpty ? -1 : mtime` keeps a page that produced zero embedded chunks marked stale (`-1` never equals a real page mtime) so a later run with a live server retries it. A genuinely empty-body page produces no chunks and harmlessly retries each startup (cheap — no embed calls).

- [ ] **Step 2: Wire it into startup**

In `AppDelegate.swift`, in `startEmbeddingServerAndBackfill`, after line 226 (`await brainIndex.backfillEmbeddings(...)`):

```swift
                await brainIndex.backfillEmbeddings(service: service, store: store)
                await brainIndex.backfillChunks(service: service, store: ChunkStore(dbQueue: brainIndex.dbQueue))
```

- [ ] **Step 3: Write the failing test (fake embedder, no network)**

Add to `LocalpenTests/BrainIndexTests.swift`. If the file already defines a fake `EmbeddingService`, reuse it; otherwise `EmbeddingService` hits a local server, so this test asserts the *staleness drains* path using a real (possibly-down) service is unsuitable — instead assert chunking happened by pre-seeding via `ChunkStore` is wrong too. Use the embedding server only if present; gate the test on it:

```swift
    func test_backfillChunks_populatesChunksForStalePages() async throws {
        // Requires the embedding server (EmbeddingGemma) to be up on the default port.
        // Skips cleanly if it isn't, so CI without the model doesn't fail.
        let service = EmbeddingService(port: 11435)
        guard (try? await service.embed("probe", kind: .query)) != nil else {
            throw XCTSkip("embedding server not running; chunk-backfill is integration-only")
        }
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("bi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("people"), withIntermediateDirectories: true)
        try "---\ntype: person\n---\n## Launch\nAna owns the Q3 launch.".write(
            to: vault.appendingPathComponent("people/Ana.md"), atomically: true, encoding: .utf8)

        let index = try BrainIndex(testInMemory: true)
        await index.reindexAll(root: vault)
        let store = ChunkStore(dbQueue: index.dbQueue)
        XCTAssertFalse(try await store.staleOrUnchunkedPaths().isEmpty, "page starts unchunked")

        await index.backfillChunks(service: service, store: store)

        XCTAssertTrue(try await store.staleOrUnchunkedPaths().isEmpty, "backfill drains staleness")
        let path = vault.appendingPathComponent("people/Ana.md").path
        let rows = try await store.loadChunks(forPaths: [path])
        XCTAssertFalse(rows.isEmpty, "chunks were embedded + stored")
        XCTAssertEqual(rows[0].vector.count, EmbeddingService.dim)
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/BrainIndexTests/test_backfillChunks_populatesChunksForStalePages 2>&1 | tail -20`
Expected: PASS (or `Test Skipped` if the embedding server is down — acceptable; this is the integration seam). The pure logic is covered by Tasks 1–2; this test guards the wiring when the server is up.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/BrainIndex.swift Localpen/AppDelegate.swift LocalpenTests/BrainIndexTests.swift
git commit -m "feat(brain): backfill chunk embeddings at startup (after page backfill)"
```

---

### Task 4: `MentionResolver` — detect + resolve named entities (pure)

**Files:**
- Create: `Localpen/Services/Brain/MentionResolver.swift`
- Test: `LocalpenTests/MentionResolverTests.swift`

**Interfaces:**
- Consumes: `KBPage`, `KBPageType`, `ProjectMatcher.normalize(_:)`.
- Produces:
  ```swift
  struct DetectedMention: Equatable { let title: String; let type: KBPageType; let origin: Origin
      enum Origin: Equatable { case explicit, auto } }
  struct MentionDetection: Equatable { var mentions: [DetectedMention] = []; var unresolved: [String] = [] }
  enum MentionResolver {
      /// Detect mentions in `instruction` + `selection` against `candidates` (people/project pages).
      /// Explicit `[[name]]`/`@name` are authoritative (unmatched ⇒ `unresolved`); remaining
      /// candidate titles appearing as whole-word/phrase matches are added as `.auto`.
      static func detect(instruction: String, selection: String?, candidates: [KBPage]) -> MentionDetection
      /// Strip `[[ ]]` / leading-`@` markup so the model reads plain prose ("…about Ana").
      static func stripMarkup(_ text: String) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class MentionResolverTests: XCTestCase {
    private func page(_ title: String, _ type: KBPageType) -> KBPage {
        KBPage(path: "/v/\(title).md", title: title, type: type, area: "", body: "",
               outboundLinks: [], tags: [], mtime: Date(timeIntervalSince1970: 0), frontmatter: [:])
    }
    private lazy var cands = [page("Ana", .person), page("Ben", .person),
                              page("Project Atlas", .project), page("Sparrow", .project)]

    func test_explicitWikilink_resolvesToPage() {
        let d = MentionResolver.detect(instruction: "reply using what I know about [[Ana]]",
                                       selection: nil, candidates: cands)
        XCTAssertEqual(d.mentions, [DetectedMention(title: "Ana", type: .person, origin: .explicit)])
        XCTAssertTrue(d.unresolved.isEmpty)
    }

    func test_explicitAtMention_resolves() {
        let d = MentionResolver.detect(instruction: "ping @Ben about it", selection: nil, candidates: cands)
        XCTAssertEqual(d.mentions.map(\.title), ["Ben"])
    }

    func test_explicitUnmatched_isUnresolved_notAuto() {
        let d = MentionResolver.detect(instruction: "ask [[Zelda]]", selection: nil, candidates: cands)
        XCTAssertTrue(d.mentions.isEmpty)
        XCTAssertEqual(d.unresolved, ["Zelda"])
    }

    func test_autoDetect_wholeWordOnly_notSubstring() {
        // "Ana" must NOT match inside "Banana".
        let d = MentionResolver.detect(instruction: "I ate a Banana today", selection: nil, candidates: cands)
        XCTAssertTrue(d.mentions.isEmpty)
    }

    func test_autoDetect_matchesWholeWord_andMultiWordTitle() {
        let d = MentionResolver.detect(instruction: "update on Project Atlas with Ben",
                                       selection: nil, candidates: cands)
        XCTAssertEqual(Set(d.mentions.map(\.title)), ["Project Atlas", "Ben"])
        XCTAssertTrue(d.mentions.allSatisfy { $0.origin == .auto })
    }

    func test_explicitWins_overAuto_forSameTitle() {
        let d = MentionResolver.detect(instruction: "[[Ana]] and also Ana again",
                                       selection: nil, candidates: cands)
        XCTAssertEqual(d.mentions, [DetectedMention(title: "Ana", type: .person, origin: .explicit)],
                       "a title is listed once, explicit origin taking precedence")
    }

    func test_normalizedFuzzyMatch_onExplicit() {
        let d = MentionResolver.detect(instruction: "see [[project-atlas]]", selection: nil, candidates: cands)
        XCTAssertEqual(d.mentions.map(\.title), ["Project Atlas"], "normalized title match (kebab ↔ Title Case)")
    }

    func test_stripMarkup_removesWikilinkAndAt() {
        XCTAssertEqual(MentionResolver.stripMarkup("about [[Ana]] and @Ben now"), "about Ana and Ben now")
        XCTAssertEqual(MentionResolver.stripMarkup("[[Project Atlas]] ships"), "Project Atlas ships")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/MentionResolverTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'MentionResolver' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Detects the people/projects a user named in a writing instruction (W2). Pure + total so
/// detection is unit-testable with a fixed candidate list. Explicit `[[name]]`/`@name` are
/// authoritative; auto-detection adds candidate titles that appear as whole words/phrases.
struct DetectedMention: Equatable {
    let title: String
    let type: KBPageType
    let origin: Origin
    enum Origin: Equatable { case explicit, auto }
}

struct MentionDetection: Equatable {
    var mentions: [DetectedMention] = []
    var unresolved: [String] = []
}

enum MentionResolver {
    static func detect(instruction: String, selection: String?, candidates: [KBPage]) -> MentionDetection {
        let haystack = [instruction, selection ?? ""].joined(separator: " ")
        var result = MentionDetection()
        var claimed = Set<String>()   // normalized titles already added

        // Index candidates by normalized title; shortest title wins a tie (most specific page).
        var byNorm: [String: KBPage] = [:]
        for p in candidates {
            let n = ProjectMatcher.normalize(p.title)
            if n.isEmpty { continue }
            if let existing = byNorm[n], existing.title.count <= p.title.count { continue }
            byNorm[n] = p
        }

        // 1. Explicit: [[name]] and @name (authoritative).
        for name in Self.explicitNames(in: instruction) + Self.explicitNames(in: selection ?? "") {
            let n = ProjectMatcher.normalize(name)
            guard !n.isEmpty, !claimed.contains(n) else { continue }
            if let page = byNorm[n] {
                claimed.insert(n)
                result.mentions.append(.init(title: page.title, type: page.type, origin: .explicit))
            } else if !result.unresolved.contains(name) {
                result.unresolved.append(name)
            }
        }

        // 2. Auto: candidate titles appearing as a contiguous whole-word phrase in the text.
        let textTokens = Self.wordTokens(haystack)
        for p in candidates {
            let n = ProjectMatcher.normalize(p.title)
            guard !n.isEmpty, !claimed.contains(n), byNorm[n]?.title == p.title else { continue }
            if Self.containsPhrase(Self.wordTokens(p.title), in: textTokens) {
                claimed.insert(n)
                result.mentions.append(.init(title: p.title, type: p.type, origin: .auto))
            }
        }
        return result
    }

    static func stripMarkup(_ text: String) -> String {
        var out = text
        // [[Anything]] → Anything  (keep inner text)
        out = out.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        // @Word → Word
        out = out.replacingOccurrences(of: #"@([\p{L}\p{N}_-]+)"#, with: "$1", options: .regularExpression)
        return out
    }

    // MARK: - helpers

    private static func explicitNames(in text: String) -> [String] {
        var names: [String] = []
        for m in matches(#"\[\[([^\]]+)\]\]"#, in: text) { names.append(m) }
        for m in matches(#"@([\p{L}\p{N}_-]+)"#, in: text) { names.append(m) }
        return names
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    /// Lowercased alphanumeric word tokens (so "Project Atlas" → ["project","atlas"]).
    private static func wordTokens(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// True if `needle` token sequence is a contiguous subsequence of `hay` (whole-word match).
    private static func containsPhrase(_ needle: [String], in hay: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<start+needle.count]) == needle {
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/MentionResolverTests 2>&1 | tail -20`
Expected: PASS — `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/MentionResolver.swift LocalpenTests/MentionResolverTests.swift
git commit -m "feat(brain): MentionResolver — detect [[name]]/@name + auto whole-word matches"
```

---

### Task 5: `MentionGrounding` — header + chunk ranking (pure)

**Files:**
- Create: `Localpen/Services/Brain/MentionGrounding.swift`
- Test: `LocalpenTests/MentionGroundingTests.swift`

**Interfaces:**
- Consumes: `PeopleInsights.Person`, `KBPage`, `ChunkStore.ChunkRow`, `VectorMath.cosine(_:_:)`.
- Produces:
  ```swift
  enum MentionGrounding {
      /// One-line orientation header for a person, omitting absent fields. nil ⇒ no header line.
      static func personHeader(_ p: PeopleInsights.Person) -> String?
      /// One-line header for a project from `status`/`stage` frontmatter. nil ⇒ no header line.
      static func projectHeader(_ page: KBPage) -> String?
      /// Chunks ranked by cosine to the query vector, best first, capped to `limit`.
      static func rankChunks(_ chunks: [ChunkStore.ChunkRow], queryVector: [Float], limit: Int) -> [ChunkStore.ChunkRow]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class MentionGroundingTests: XCTestCase {
    func test_personHeader_includesPresentFields() {
        let page = KBPage(path: "/v/Ana.md", title: "Ana", type: .person, area: "people", body: "",
                          outboundLinks: [], tags: [], mtime: Date(timeIntervalSince1970: 0),
                          frontmatter: ["relationship_tier": "close", "last_contact": "2026-05-27", "follow_up": "reply re: launch"])
        let today = ISO8601DateFormatter().date(from: "2026-06-17T00:00:00Z")!   // 21 days after last_contact
        let person = PeopleInsights.person(from: page, today: today)
        let header = MentionGrounding.personHeader(person)
        XCTAssertNotNil(header)
        XCTAssertTrue(header!.contains("close"))
        XCTAssertTrue(header!.contains("follow-up: reply re: launch"))
        XCTAssertTrue(header!.contains("21d"))
    }

    func test_personHeader_onlyTier_whenOthersAbsent() {
        let page = KBPage(path: "/v/X.md", title: "X", type: .person, area: "people", body: "",
                          outboundLinks: [], tags: [], mtime: Date(timeIntervalSince1970: 0), frontmatter: [:])
        let person = PeopleInsights.person(from: page, today: Date(timeIntervalSince1970: 0))
        // tier defaults to "casual" → header surfaces tier only.
        XCTAssertEqual(MentionGrounding.personHeader(person), "casual tier")
    }

    func test_rankChunks_ordersByCosine_andCaps() {
        func row(_ i: Int, _ v: [Float]) -> ChunkStore.ChunkRow {
            .init(path: "/v/A.md", index: i, heading: nil, text: "c\(i)", vector: v)
        }
        let q: [Float] = [1, 0, 0]
        let chunks = [row(0, [0, 1, 0]), row(1, [0.9, 0.1, 0]), row(2, [0.5, 0.5, 0])]
        let ranked = MentionGrounding.rankChunks(chunks, queryVector: q, limit: 2)
        XCTAssertEqual(ranked.map(\.index), [1, 2], "most cosine-similar first, capped to 2")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/MentionGroundingTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'MentionGrounding' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Formats grounding for a resolved mention (W2): a one-line orientation header + cosine-ranked
/// chunk selection. Pure so ranking/formatting are unit-testable without a DB or server.
enum MentionGrounding {
    static func personHeader(_ p: PeopleInsights.Person) -> String? {
        var parts = ["\(p.tier) tier"]
        if let d = p.daysSinceContact { parts.append("last contact \(d)d ago") }
        if let f = p.followUp { parts.append("follow-up: \(f)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func projectHeader(_ page: KBPage) -> String? {
        let fields = ["status", "stage"].compactMap { key -> String? in
            PeopleInsights.cleaned(page.frontmatter[key]).map { "\(key): \($0)" }
        }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    static func rankChunks(_ chunks: [ChunkStore.ChunkRow], queryVector: [Float], limit: Int) -> [ChunkStore.ChunkRow] {
        chunks
            .map { (row: $0, sim: VectorMath.cosine(queryVector, $0.vector)) }
            .sorted { $0.sim > $1.sim }
            .prefix(limit)
            .map(\.row)
    }
}
```

> `personHeader` always returns at least the tier (`PeopleInsights.person` defaults tier to `"casual"`), so it is never nil for a real person — matching `test_personHeader_allAbsent_isNil`'s expectation of `"casual tier"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/MentionGroundingTests 2>&1 | tail -20`
Expected: PASS — `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/MentionGrounding.swift LocalpenTests/MentionGroundingTests.swift
git commit -m "feat(brain): MentionGrounding — entity header + cosine chunk ranking"
```

---

### Task 6: `ContextEngine.bundle(for:mentions:)` — prioritize mention pages

**Files:**
- Modify: `Localpen/Services/Brain/KBModels.swift` (add `.mention` to `ContextBundle.Provenance.Reason`)
- Modify: `Localpen/Services/Brain/ContextEngine.swift` (mention detection + grounding + budget)
- Test: `LocalpenTests/ContextEngineTests.swift` (add mention-grounding cases)

**Interfaces:**
- Consumes: `MentionResolver.detect`, `MentionGrounding`, `ChunkStore`, `index.pages(ofType:)`, `index.pageByTitle(_:)`, `index.backlinks(toTitle:)`, `PeopleInsights.person(from:today:)`.
- Produces: `func bundle(for query: String, mentions: [DetectedMention]? = nil) async -> ContextBundle` (existing callers unchanged; `nil` ⇒ auto-detect).

- [ ] **Step 1: Add the `.mention` provenance reason**

In `KBModels.swift`, change:
```swift
        enum Reason: String, Sendable, Codable { case always, query }
```
to:
```swift
        enum Reason: String, Sendable, Codable { case always, query, mention }
```

- [ ] **Step 2: Write the failing tests** (append to `ContextEngineTests.swift`)

```swift
    // MARK: - W2 mention grounding

    func test_bundle_explicitMention_groundsEntityPage_withMentionProvenance() async throws {
        try writeFile("self/About.md", "---\ntype: self\n---\nid")
        try writeFile("people/Ana.md", "---\ntype: person\nrelationship_tier: close\n---\nAna owns the Q3 launch and prefers terse updates.")
        let index = try BrainIndex(testInMemory: true)
        await index.reindexAll(root: vault)
        let engine = ContextEngine(search: KBSearch(dbQueue: index.dbQueue), index: index,
                                   config: BrainConfig(vaultRoot: vault), isBrainEnabled: { true })

        // No embedding service ⇒ degradation path: mention page condensed (still grounded).
        let bundle = await engine.bundle(for: "draft a reply to [[Ana]] about the launch")
        XCTAssertTrue(bundle.sources.contains { $0.title == "Ana" && $0.reason == .mention },
                      "the named entity is grounded with .mention provenance")
        XCTAssertTrue(bundle.text.contains("kb [Ana"))
    }

    func test_bundle_noMention_behavesAsBefore() async throws {
        try writeFile("self/About.md", "---\ntype: self\n---\nid")
        try writeFile("people/Ana.md", "---\ntype: person\n---\nAna stuff")
        let index = try BrainIndex(testInMemory: true)
        await index.reindexAll(root: vault)
        let engine = ContextEngine(search: KBSearch(dbQueue: index.dbQueue), index: index,
                                   config: BrainConfig(vaultRoot: vault), isBrainEnabled: { true })

        let bundle = await engine.bundle(for: "quantum chromodynamics")   // names nothing
        XCTAssertFalse(bundle.sources.contains { $0.reason == .mention }, "no mentions ⇒ no .mention lines")
    }

    func test_bundle_brainDisabled_stillEmpty_withMentionInQuery() async throws {
        let engine = try makeEngine(config: BrainConfig(vaultRoot: vault), enabled: false)
        let bundle = await engine.bundle(for: "reply to [[Ana]]")
        XCTAssertEqual(bundle, .empty, "brain off ⇒ empty even when the query names an entity")
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ContextEngineTests 2>&1 | tail -25`
Expected: FAIL — the new mention tests fail (`.mention` lines absent); existing tests still pass.

- [ ] **Step 4: Implement mention grounding in `ContextEngine`**

Add a stored `today` source for deterministic testing is not needed here (uses `Date()` only for header day-math; acceptable — headers aren't asserted in engine tests). Replace the body of `bundle(for:)` and add helpers:

```swift
    func bundle(for query: String, mentions: [DetectedMention]? = nil) async -> ContextBundle {
        guard isBrainEnabled() else { return .empty }

        var picked: [(page: KBPage, reason: ContextBundle.Provenance.Reason)] = []
        var used = Set<String>()
        var lines: [String] = []
        var sources: [ContextBundle.Provenance] = []
        var budget = config.maxContextTokens

        // self/ + now.md first (identity always claims the budget).
        for page in await index.alwaysPages(areas: config.alwaysIncludeAreas, files: config.alwaysIncludeFiles)
        where used.insert(page.path).inserted {
            picked.append((page, .always))
        }
        func emit(_ snippet: String, _ page: KBPage, _ reason: ContextBundle.Provenance.Reason, label: String? = nil) {
            guard !snippet.isEmpty else { return }
            let cost = Self.approxTokens(snippet)
            guard cost <= budget else { return }
            lines.append("kb [\(label ?? page.title)]: \(snippet)")
            sources.append(.init(title: page.title, path: page.path, reason: reason))
            budget -= cost
        }
        // always pages
        for (page, reason) in picked { emit(Self.condense(page.body, charCap: config.perPageCharCap), page, reason) }

        // Mention grounding (explicit + auto), prioritized before generic query hits.
        let resolved = mentions ?? (await autoDetect(in: query))
        await groundMentions(resolved, query: query, used: &used, budget: &budget, lines: &lines, sources: &sources)

        // Generic query hits fill whatever budget remains.
        for hit in await queryHits(for: query) where used.insert(hit.page.path).inserted {
            emit(Self.condense(hit.page.body, charCap: config.perPageCharCap), hit.page, .query)
        }

        return ContextBundle(text: lines.joined(separator: "\n"), sources: sources,
                             approxTokens: config.maxContextTokens - budget)
    }

    /// Detect mentions from the brain's people/project pages when the caller didn't pass an
    /// explicit (user-confirmed) set. Plan B passes a confirmed list and skips this.
    private func autoDetect(in query: String) async -> [DetectedMention] {
        let candidates = await index.pages(ofType: .person) + index.pages(ofType: .project)
        return MentionResolver.detect(instruction: query, selection: nil, candidates: candidates).mentions
    }

    /// Ground each resolved mention: a header line + cosine-ranked chunks of the entity page,
    /// explicit before auto, each entity's primary slice (header + top chunk) funded before any
    /// neighborhood. Degrades to a condensed page snippet when chunks/embeddings are unavailable.
    private func groundMentions(_ mentions: [DetectedMention], query: String, used: inout Set<String>,
                                budget: inout Int, lines: inout [String], sources: inout [ContextBundle.Provenance]) async {
        let ordered = mentions.sorted { ($0.origin == .explicit ? 0 : 1) < ($1.origin == .explicit ? 0 : 1) }
        guard !ordered.isEmpty else { return }

        let chunkStore = ChunkStore(dbQueue: index.dbQueue)
        let queryVector: [Float]? = await {
            guard let embeddingService else { return nil }
            return try? await embeddingService.embed(query, kind: .query)
        }()

        for m in ordered {
            guard let page = await index.pageByTitle(m.title), used.insert(page.path).inserted else { continue }
            // header
            let header: String? = page.type == .person
                ? MentionGrounding.personHeader(PeopleInsights.person(from: page, today: Date()))
                : MentionGrounding.projectHeader(page)
            // chunks (primary slice = top-ranked own-page chunk)
            var emittedBody = false
            if let qv = queryVector,
               let chunks = try? await chunkStore.loadChunks(forPaths: [page.path]), !chunks.isEmpty {
                let ranked = MentionGrounding.rankChunks(chunks, queryVector: qv, limit: 2)
                for ch in ranked {
                    let label = ch.heading.map { "\(page.title) › \($0)" } ?? page.title
                    let body = [header, ch.text].compactMap { $0 }.joined(separator: " — ")
                    let snippet = emittedBody ? ch.text : body
                    let cost = Self.approxTokens(snippet)
                    guard cost <= budget else { break }
                    lines.append("kb [\(label)]: \(snippet)")
                    sources.append(.init(title: page.title, path: page.path, reason: .mention))
                    budget -= cost
                    emittedBody = true
                }
            }
            // degradation: no chunks ⇒ header + condensed page head as one line.
            if !emittedBody {
                let body = [header, ContextEngine.condense(page.body, charCap: config.perPageCharCap)]
                    .compactMap { $0 }.joined(separator: " — ")
                let cost = Self.approxTokens(body)
                if !body.isEmpty, cost <= budget {
                    lines.append("kb [\(page.title)]: \(body)")
                    sources.append(.init(title: page.title, path: page.path, reason: .mention))
                    budget -= cost
                }
            }
        }
    }
```

> `PeopleInsights.cleaned` is `static` and currently used cross-type — confirm it's accessible from `MentionGrounding` (same module, `enum PeopleInsights` with `static func cleaned`). It is `internal`, so no change needed.
> Neighborhood (`backlinks`) is deferred to keep Task 6 focused on the primary-page slice + budget; add it as a follow-up step only if the primary path is green and budget remains. (YAGNI for the first green build; the spec's neighborhood is a Plan-A stretch, not required for the flagship.)

- [ ] **Step 5: Run the full ContextEngine suite**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ContextEngineTests 2>&1 | tail -25`
Expected: PASS — all prior tests + the 3 new mention tests green.

- [ ] **Step 6: Commit**

```bash
git add Localpen/Services/Brain/KBModels.swift Localpen/Services/Brain/ContextEngine.swift LocalpenTests/ContextEngineTests.swift
git commit -m "feat(brain): bundle() grounds named-entity mentions before generic hits"
```

---

### Task 7: Wire grounding into respond / custom / ask

**Files:**
- Modify: `Localpen/Models/ActionPrompts.swift` (add optional `knowledge:` to `userMessage(for:text:)`)
- Modify: `Localpen/Panel/PanelController.swift` (`runStream` grounds respond/custom; `startAskStream` strips markup)
- Test: `LocalpenTests/` — add an `ActionPrompts` knowledge-wrapping test (pure); controller paths are verified by build + the existing brain on/off prompt-equality test + a hand visual check.

**Interfaces:**
- Consumes: `ContextEngine.bundle(for:)`, `MentionResolver.stripMarkup(_:)`.
- Produces: `ActionPrompts.userMessage(for:text:knowledge:)` (knowledge defaults nil ⇒ existing callers byte-identical).

- [ ] **Step 1: Write the failing `ActionPrompts` test**

Add to `LocalpenTests/` (e.g. a new `ActionPromptsTests.swift` or an existing prompt test file):

```swift
import XCTest
@testable import Localpen

final class ActionPromptsKnowledgeTests: XCTestCase {
    func test_userMessage_noKnowledge_isUnchanged() {
        let out = ActionPrompts.userMessage(for: .respond("be warm"), text: "Hi there")
        XCTAssertEqual(out, "Message to reply to:\nHi there\n\nHow to reply: be warm")
    }

    func test_userMessage_withKnowledge_prependsContextBlock() {
        let out = ActionPrompts.userMessage(for: .respond("be warm"), text: "Hi there",
                                            knowledge: "kb [Ana]: close tier")
        XCTAssertEqual(out, "<context>\nkb [Ana]: close tier\n</context>\n\nMessage to reply to:\nHi there\n\nHow to reply: be warm")
    }

    func test_userMessage_customWithKnowledge_prependsContextBlock() {
        let out = ActionPrompts.userMessage(for: .custom("make it punchy"), text: "Draft",
                                            knowledge: "kb [Sparrow]: status: shipping")
        XCTAssertTrue(out.hasPrefix("<context>\nkb [Sparrow]: status: shipping\n</context>\n\n"))
        XCTAssertTrue(out.hasSuffix("Instruction: make it punchy\n\nText:\nDraft"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ActionPromptsKnowledgeTests 2>&1 | tail -20`
Expected: FAIL — `userMessage(for:text:knowledge:)` has no `knowledge:` parameter (compile error).

- [ ] **Step 3: Add `knowledge:` to `userMessage`**

In `ActionPrompts.swift`, change the signature and wrap the result for the non-ask cases:

```swift
    static func userMessage(for action: Action, text: String, knowledge: String? = nil) -> String {
        let body: String
        switch action {
        case .custom(let instruction):
            body = text.isEmpty ? instruction : "Instruction: \(instruction)\n\nText:\n\(text)"
        case .respond(let steer):
            let base = "Message to reply to:\n\(text)"
            body = steer.isEmpty ? base : "\(base)\n\nHow to reply: \(steer)"
        case .ask(let question, _):
            // Ask routes through askUserMessage (its own <context> assembly); knowledge is
            // injected there via AskContext.knowledge, not here.
            return askUserMessage(question: question,
                                  context: AskContext(appLabel: nil, selection: text.isEmpty ? nil : text))
        default:
            body = text
        }
        guard let kb = knowledge, !kb.isEmpty else { return body }
        return "<context>\n\(kb)\n</context>\n\n\(body)"
    }
```

- [ ] **Step 4: Run to verify the `ActionPrompts` test passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ActionPromptsKnowledgeTests 2>&1 | tail -20`
Expected: PASS — `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Ground respond/custom in `runStream`**

In `PanelController.runStream(action:selection:)`, replace lines 1000–1002 with:

```swift
        let baseSystemPrompt = registry.systemPrompt(for: action)
        let systemPrompt = memory?.compose(base: baseSystemPrompt, for: action) ?? baseSystemPrompt

        // W2: ground respond/custom in the people/projects named in the instruction. Other
        // actions (proofread/polish/…) carry no instruction, so this no-ops for them.
        var knowledge: String? = nil
        if let engine = contextEngine, action.groundsInBrain {
            let selText = selection?.text ?? ""
            let groundingQuery = "\(action.instructionText) \(selText)"
            let kb = await engine.bundle(for: groundingQuery)
            if !kb.text.isEmpty { knowledge = kb.text }
        }
        let userPrompt = ActionPrompts.userMessage(
            for: action,
            text: MentionResolver.stripMarkup(selection?.text ?? ""),
            knowledge: knowledge)
```

Add two helpers to `Action` (in `Localpen/Models/Action.swift`):

```swift
    /// Actions whose instruction can name a person/project to ground on (W2). The 6 fixed
    /// quick-actions take no instruction, so they never ground.
    var groundsInBrain: Bool {
        switch self { case .respond, .custom, .ask: return true; default: return false }
    }
    /// The user-supplied steering text for grounding detection ("" for fixed actions).
    var instructionText: String {
        switch self {
        case .respond(let s): return s
        case .custom(let s): return s
        case .ask(let q, _): return q
        default: return ""
        }
    }
```

> Note: `stripMarkup` is applied to the *selection text* so any `[[ ]]` the user pasted into the operand reads as prose; the instruction text reaches the model through the action's own prompt template (respond/custom), so strip it there too if the steer contains markup — for v1 the steer is short and the chip-row (Plan B) is where markup is authored, so leaving the steer untouched is acceptable. Detection still runs on the raw `instructionText` (markup intact) above.

- [ ] **Step 6: Strip markup in the ask path**

In `PanelController.startAskStream`, the question is grounded via `engine.bundle(for: question)` (now auto-detects mentions). Strip markup from the question shown to the model. Change line 1391:

```swift
            let strippedQuestion = MentionResolver.stripMarkup(question)
            let userMessage = ActionPrompts.askUserMessage(question: strippedQuestion, context: ctx)
```

(Leave line 1385 `engine.bundle(for: question)` using the raw `question` so `[[ ]]` is still detected.)

- [ ] **Step 7: Build + run the full brain/prompt suite**

Run:
```bash
xcodebuild test -scheme Localpen -destination 'platform=macOS' \
  -only-testing:LocalpenTests/ContextEngineTests \
  -only-testing:LocalpenTests/ActionPromptsKnowledgeTests \
  -only-testing:LocalpenTests/AskContextTests \
  -only-testing:LocalpenTests/MentionResolverTests 2>&1 | tail -25
```
Expected: PASS across all. Then a full build: `xcodebuild build -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -5` → `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add Localpen/Models/ActionPrompts.swift Localpen/Models/Action.swift Localpen/Panel/PanelController.swift LocalpenTests/ActionPromptsKnowledgeTests.swift
git commit -m "feat(w2): respond/custom/ask ground on named people/projects (markup stripped)"
```

- [ ] **Step 9: Hand visual check (user)**

Rebuild + install (`scripts/rebuild-install.sh`), then with the brain on and a `[[Person]]` page present: select a short message, invoke Respond with `using what I know about [[Name]]`, confirm the draft reflects the person's notes. (Per working style — no scripted hotkey testing; user does the visual check.)

---

## Recall-gate regression check (run once after Task 6)

The page-level ask recall gate must be unchanged (chunks didn't disturb it). Run the existing gold-set recall test (locate it: `grep -rn "recall" LocalpenTests/`), e.g.:

`xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/<RecallGateTest> 2>&1 | tail -15`
Expected: unchanged pass.

## Done-when

- `[[Name]]` (or a bare matching name) in a respond/custom instruction grounds the draft in that page's most-relevant chunks, headered with relationship/status context, in the user's voice.
- Brain-off / server-down / unembedded-page all degrade to today's exact prompt (the brain on/off equality test still passes).
- All new unit suites green; full build succeeds; recall gate unchanged.
- Plan B (mention autocomplete, pre-generation chip row, one-shot result provenance) follows.
