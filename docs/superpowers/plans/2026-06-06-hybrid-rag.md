# Hybrid RAG (feat/hybrid-rag) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade Localpen's brain retrieval from FTS5-keyword-only to **hybrid** retrieval — BM25 fused with on-device dense embeddings (EmbeddingGemma) via Reciprocal Rank Fusion — so semantic/paraphrase queries that keyword search misses are found.

**Architecture:** A second local `llama-server --embeddings` (EmbeddingGemma) produces vectors; cxkb-page vectors are stored as BLOBs in a new `page_embeddings` table in `brain.sqlite` (no sqlite-vec extension — the corpus is small, so brute-force cosine in memory is sufficient and avoids macOS extension-codesigning pain). `KBSearch` runs the existing BM25 query and a dense cosine query independently, then fuses their *ranks* with RRF. The `KBSearch.score` seam (already documented "embeddings later extend this") is where fusion lands.

**Tech Stack:** Swift, GRDB (existing `brain.sqlite`), llama.cpp `llama-server` `/embedding` endpoint, EmbeddingGemma-300M GGUF, XCTest.

**Branch:** `feat/hybrid-rag` off `main`. This branch **owns all `LlamaServerController` changes** (per the parallel-build-map collision note); the harness/quickwins branches rebase on it.

**Model-version contract (ADR 0023 — must match cx-news):** model `embeddinggemma-300m`, output dim **256** (Matryoshka-truncated), pooling **mean**, prefixes: query = `task: search result | query: <text>`, document = `title: none | text: <text>`. These constants live in `EmbeddingService` and are the shared interface — do not change unilaterally.

---

## File structure

- **Create** `Localpen/Services/Brain/VectorMath.swift` — pure cosine + `[Float]`↔`Data` BLOB helpers. No imports beyond Foundation.
- **Create** `Localpen/Services/Brain/RankFusion.swift` — pure RRF over ranked path lists.
- **Create** `Localpen/Services/Brain/EmbeddingService.swift` — HTTP client to the embedding server + the model-version contract constants + prefixing.
- **Create** `Localpen/Services/Brain/EmbeddingStore.swift` — read/write `page_embeddings` + load-all into memory.
- **Modify** `Localpen/Services/Brain/BrainIndex.swift` — add `v2.page_embeddings` migration; embed-on-upsert hook.
- **Modify** `Localpen/Services/Brain/KBSearch.swift` — hybrid search (BM25 ∪ dense, RRF-fused). The pure-FTS path stays as a fallback when embeddings are absent.
- **Modify** `Localpen/Panel/LlamaServerController.swift` — spawn the aux embedding server.
- **Tests** `LocalpenTests/VectorMathTests.swift`, `LocalpenTests/RankFusionTests.swift`, `LocalpenTests/EmbeddingStoreTests.swift`, `LocalpenTests/HybridSearchTests.swift`.

**Build order:** Tasks 1–4 are pure/storage and need NO model or server — start here immediately. Task 5 (embedding server + model) is the one integration unknown. Tasks 6–8 wire it together.

---

## Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/charliexue/School/cs_misc/localpen
git checkout -b feat/hybrid-rag
```

---

## Task 1: VectorMath (pure cosine + BLOB codec)

**Files:**
- Create: `Localpen/Services/Brain/VectorMath.swift`
- Test: `LocalpenTests/VectorMathTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Localpen

final class VectorMathTests: XCTestCase {
    func test_cosine_identicalVectorsIsOne() {
        let v: [Float] = [1, 2, 3]
        XCTAssertEqual(VectorMath.cosine(v, v), 1.0, accuracy: 1e-5)
    }
    func test_cosine_orthogonalIsZero() {
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-5)
    }
    func test_cosine_mismatchedLengthOrZeroIsZero() {
        XCTAssertEqual(VectorMath.cosine([1, 2, 3], [1, 2]), 0.0)
        XCTAssertEqual(VectorMath.cosine([0, 0], [0, 0]), 0.0)
    }
    func test_blobRoundTrip() {
        let v: [Float] = [0.5, -1.25, 3.0, 0]
        XCTAssertEqual(VectorMath.floats(from: VectorMath.data(from: v)), v)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VectorMathTests`
Expected: FAIL — `VectorMath` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure vector helpers for dense retrieval. Brute-force cosine is fine at vault scale
/// (~hundreds–thousands of vectors); no ANN / sqlite-vec needed.
enum VectorMath {
    /// Cosine similarity in [-1, 1]. Returns 0 on length mismatch or a zero vector
    /// (degenerate inputs rank last rather than crashing).
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// `[Float]` → little-endian BLOB for sqlite storage, and back.
    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func floats(from data: Data) -> [Float] {
        var out = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VectorMathTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/VectorMath.swift LocalpenTests/VectorMathTests.swift
git commit -m "feat(brain): VectorMath — pure cosine + float-blob codec for dense retrieval"
```

---

## Task 2: RankFusion (pure RRF)

**Files:**
- Create: `Localpen/Services/Brain/RankFusion.swift`
- Test: `LocalpenTests/RankFusionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Localpen

final class RankFusionTests: XCTestCase {
    func test_rrf_itemHighInBothListsWinsOverItemHighInOne() {
        // "b" is rank-2 in both; "a" is rank-1 in one and absent in the other.
        let bm = ["a", "b", "c"]
        let dense = ["d", "b", "a"]
        let fused = RankFusion.rrf([bm, dense], k: 60)
        XCTAssertEqual(fused.first, "b", "agreement across lists beats a single strong list")
    }
    func test_rrf_unionOfAllItems() {
        let fused = RankFusion.rrf([["a"], ["b"]], k: 60)
        XCTAssertEqual(Set(fused), ["a", "b"])
    }
    func test_rrf_emptyListsIsEmpty() {
        XCTAssertTrue(RankFusion.rrf([[], []], k: 60).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/RankFusionTests`
Expected: FAIL — `RankFusion` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Reciprocal Rank Fusion: combine ranked lists by *rank position*, sidestepping the
/// BM25-score vs cosine-score incompatibility. score(item) = Σ 1/(k + rank_i).
enum RankFusion {
    /// `lists` are each ranked best-first (by id). Returns ids ordered by fused score desc.
    static func rrf(_ lists: [[String]], k: Double) -> [String] {
        var score: [String: Double] = [:]
        for list in lists {
            for (idx, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / (k + Double(idx + 1))
            }
        }
        return score.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key   // stable tiebreak
        }.map(\.key)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/RankFusionTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/RankFusion.swift LocalpenTests/RankFusionTests.swift
git commit -m "feat(brain): RankFusion — pure reciprocal rank fusion for hybrid retrieval"
```

---

## Task 3: page_embeddings storage (migration + EmbeddingStore)

**Files:**
- Modify: `Localpen/Services/Brain/BrainIndex.swift:221-260` (add a second migration after `v1.brain`)
- Create: `Localpen/Services/Brain/EmbeddingStore.swift`
- Test: `LocalpenTests/EmbeddingStoreTests.swift`

- [ ] **Step 1: Add the migration** — in `BrainIndex.migrate`, after the `m.registerMigration("v1.brain")` block closes, add:

```swift
        m.registerMigration("v2.page_embeddings") { db in
            try db.create(table: "page_embeddings") { t in
                t.column("path", .text).primaryKey()
                    .references("pages", column: "path", onDelete: .cascade)
                t.column("vector", .blob).notNull()
                t.column("dim", .integer).notNull()
                t.column("model", .text).notNull()
            }
        }
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import GRDB
@testable import Localpen

final class EmbeddingStoreTests: XCTestCase {
    private func makeIndexWithPage() async throws -> BrainIndex {
        let index = try BrainIndex(testInMemory: true)
        try await index.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pages(path,title,type,area,body,tags,mtime,frontmatter_json)
                VALUES('/v/a.md','A','note','self','body','',0,'{}')
                """)
        }
        return index
    }

    func test_upsertAndLoadAll_roundTripsVectors() async throws {
        let index = try await makeIndexWithPage()
        let store = EmbeddingStore(dbQueue: index.dbQueue)
        try await store.upsert(path: "/v/a.md", vector: [0.1, 0.2, 0.3], model: "embeddinggemma-300m")
        let all = try await store.loadAll()
        XCTAssertEqual(all["/v/a.md"], [0.1, 0.2, 0.3])
    }

    func test_deletingPageCascadesEmbedding() async throws {
        let index = try await makeIndexWithPage()
        let store = EmbeddingStore(dbQueue: index.dbQueue)
        try await store.upsert(path: "/v/a.md", vector: [1, 2], model: "m")
        try await index.dbQueue.write { db in try db.execute(sql: "DELETE FROM pages WHERE path='/v/a.md'") }
        let all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty, "embedding is removed with its page (FK cascade)")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/EmbeddingStoreTests`
Expected: FAIL — `EmbeddingStore` undefined.

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation
import GRDB

/// Read/write cxkb-page vectors in `brain.sqlite` (BLOB, no sqlite-vec). `loadAll`
/// pulls every vector into memory for brute-force cosine — fine at vault scale.
struct EmbeddingStore {
    let dbQueue: DatabaseQueue

    func upsert(path: String, vector: [Float], model: String) async throws {
        let blob = VectorMath.data(from: vector)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO page_embeddings(path, vector, dim, model) VALUES(?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET vector=excluded.vector, dim=excluded.dim, model=excluded.model
                """, arguments: [path, blob, vector.count, model])
        }
    }

    /// path → vector, for every embedded page. Caller holds this in memory for search.
    func loadAll() async throws -> [String: [Float]] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path, vector FROM page_embeddings").reduce(into: [:]) {
                $0[$1["path"] as String] = VectorMath.floats(from: $1["vector"] as Data)
            }
        }
    }

    /// Paths that have no embedding yet (drives incremental backfill).
    func unembeddedPaths() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.path FROM pages p
                LEFT JOIN page_embeddings e ON e.path = p.path
                WHERE e.path IS NULL
                """)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/EmbeddingStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Localpen/Services/Brain/BrainIndex.swift Localpen/Services/Brain/EmbeddingStore.swift LocalpenTests/EmbeddingStoreTests.swift
git commit -m "feat(brain): page_embeddings store (v2 migration, blob vectors, FK cascade)"
```

---

## Task 4: EmbeddingService (HTTP client + contract constants)

**Files:**
- Create: `Localpen/Services/Brain/EmbeddingService.swift`
- Test: `LocalpenTests/EmbeddingServiceTests.swift` (tests the pure prefixing + response decoding; no live server)

- [ ] **Step 1: Write the failing test** (pure parts only — prefixing + decode)

```swift
import XCTest
@testable import Localpen

final class EmbeddingServiceTests: XCTestCase {
    func test_prefix_queryVsDocumentMatchContract() {
        XCTAssertEqual(EmbeddingService.prefixed("hi", kind: .query), "task: search result | query: hi")
        XCTAssertEqual(EmbeddingService.prefixed("hi", kind: .document), "title: none | text: hi")
    }
    func test_decode_pullsFirstEmbeddingArray() throws {
        // llama.cpp /embedding returns [{ "embedding": [..] }]
        let json = #"[{"embedding":[0.1,0.2,0.3]}]"#.data(using: .utf8)!
        XCTAssertEqual(try EmbeddingService.decode(json), [0.1, 0.2, 0.3])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/EmbeddingServiceTests`
Expected: FAIL — `EmbeddingService` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Client for a local `llama-server --embeddings` (EmbeddingGemma). Encapsulates the
/// ADR-0023 model-version contract: model id, dim, pooling, and the query/document
/// task-prefixes. These constants are the shared interface with cx-news — keep in lockstep.
struct EmbeddingService {
    enum Kind { case query, document }

    static let modelID = "embeddinggemma-300m"
    static let dim = 256                       // Matryoshka-truncated
    let endpoint: URL                          // e.g. http://127.0.0.1:11435/embedding

    init(port: Int = 11435) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/embedding")!
    }

    /// EmbeddingGemma requires task prefixes; mismatched prefixes degrade quality.
    static func prefixed(_ text: String, kind: Kind) -> String {
        switch kind {
        case .query:    return "task: search result | query: \(text)"
        case .document: return "title: none | text: \(text)"
        }
    }

    static func decode(_ data: Data) throws -> [Float] {
        struct Item: Decodable { let embedding: [Float] }
        let items = try JSONDecoder().decode([Item].self, from: data)
        guard let first = items.first else {
            throw NSError(domain: "Localpen", code: 110,
                          userInfo: [NSLocalizedDescriptionKey: "empty embedding response"])
        }
        return Array(first.embedding.prefix(dim))     // enforce the contract dim
    }

    func embed(_ text: String, kind: Kind) async throws -> [Float] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["content": Self.prefixed(text, kind: kind)])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Localpen", code: 111,
                          userInfo: [NSLocalizedDescriptionKey: "embedding server not OK"])
        }
        return try Self.decode(data)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/EmbeddingServiceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/EmbeddingService.swift LocalpenTests/EmbeddingServiceTests.swift
git commit -m "feat(brain): EmbeddingService — llama.cpp embedding client + ADR-0023 contract"
```

---

## Task 5: Embedding server + model acquisition  ⚠️ OPEN DECISION

**Files:**
- Modify: `Localpen/Panel/LlamaServerController.swift`

**Open decision (resolve before this task):** where the EmbeddingGemma GGUF comes from. Per ADR 0002 Localpen downloads models on first run. Recommended: download `embeddinggemma-300m` Q8_0 GGUF on first run alongside the main model (reuse the existing main-model download/registry flow — read `ModelRegistry` + the first-run downloader and mirror it). Until that's wired, an agent can point at a hand-placed GGUF path via a debug default so Tasks 6–8 are testable. **Flag to the human; do not invent a download UI.**

- [ ] **Step 1: Add an embedding-server launcher** — add to `LlamaServerController`:

```swift
    /// Port for the auxiliary embedding server (EmbeddingGemma), separate from the
    /// main chat server on `port`.
    let embeddingPort: Int = 11435
    private var embeddingProcess: Process?

    /// Spawn a second llama-server in embedding mode. Mirrors `start(...)`'s spawn +
    /// health-wait + orphan-reap, with `--embeddings --pooling mean` and no GPU-layer
    /// contention concerns (300M model). Safe to call after the main server is ready.
    func startEmbeddingServer(modelPath: String) async throws {
        // (mirror start(): fileExists guard, bundled binary lookup, reapOrphanedServers,
        //  Process with arguments below, log to Logs/Localpen/llama-embed.log,
        //  health-poll http://127.0.0.1:\(embeddingPort)/health for 20s.)
        // arguments:
        //   ["--model", modelPath, "--host", "127.0.0.1", "--port", "\(embeddingPort)",
        //    "--embeddings", "--pooling", "mean", "--ubatch-size", "8192", "--n-gpu-layers", "999"]
    }
```

Implement the body by copying the proven spawn/health/reap structure from `start(modelPath:contextSize:)` (lines 19–91), substituting the arguments above and the `embeddingPort`. Keep `embeddingProcess` for teardown; extend `stop()` to terminate it too.

- [ ] **Step 2: Manual verification** (no unit test — it spawns a real process)

Run the app (or a small harness) with a placed GGUF; confirm `curl -s http://127.0.0.1:11435/health` returns 200 and:
```bash
curl -s http://127.0.0.1:11435/embedding -d '{"content":"task: search result | query: hello"}' | head -c 120
```
Expected: a JSON array containing an `"embedding"` array.

- [ ] **Step 3: Commit**

```bash
git add Localpen/Panel/LlamaServerController.swift
git commit -m "feat(llama): aux embedding server (EmbeddingGemma, --embeddings --pooling mean)"
```

---

## Task 6: Embed pages during indexing

**Files:**
- Modify: `Localpen/Services/Brain/BrainIndex.swift` (call EmbeddingService after upsert; backfill helper)

- [ ] **Step 1: Add a backfill method** to `BrainIndex`:

```swift
    /// Embed any page lacking a vector (incremental). Best-effort: if the embedding
    /// server is down, pages stay unembedded and search falls back to BM25-only.
    func backfillEmbeddings(service: EmbeddingService, store: EmbeddingStore) async {
        guard let paths = try? await store.unembeddedPaths() else { return }
        for path in paths {
            guard let row = try? await dbQueue.read({ db in
                try Row.fetchOne(db, sql: "SELECT title, body FROM pages WHERE path = ?", arguments: [path])
            }) ?? nil else { continue }
            let text = "\(row["title"] as String? ?? "")\n\((row["body"] as String? ?? "").prefix(2000))"
            guard let vec = try? await service.embed(text, kind: .document) else { continue }
            try? await store.upsert(path: path, vector: vec, model: EmbeddingService.modelID)
        }
    }
```

- [ ] **Step 2: Verify it compiles + existing brain tests still pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/BrainIndexTests`
Expected: PASS (no regressions; new method untested-by-unit since it needs a live server — covered by Task 8's manual gold-set run).

- [ ] **Step 3: Commit**

```bash
git add Localpen/Services/Brain/BrainIndex.swift
git commit -m "feat(brain): backfill page embeddings incrementally (best-effort, BM25 fallback)"
```

---

## Task 7: Hybrid search in KBSearch (BM25 ∪ dense, RRF-fused)

**Files:**
- Modify: `Localpen/Services/Brain/KBSearch.swift`
- Test: `LocalpenTests/HybridSearchTests.swift`

- [ ] **Step 1: Write the failing test** (inject vectors directly; stub the query embedding so no server is needed)

```swift
import XCTest
import GRDB
@testable import Localpen

final class HybridSearchTests: XCTestCase {
    func test_hybrid_findsSemanticMatchKeywordSearchMisses() async throws {
        let index = try BrainIndex(testInMemory: true)
        // Two pages; the query word appears in NEITHER body (pure semantic case).
        try await index.dbQueue.write { db in
            for (path, title, body) in [("/v/cars.md","Cars","automobiles and engines"),
                                        ("/v/food.md","Food","recipes and cooking")] {
                try db.execute(sql: "INSERT INTO pages(path,title,type,area,body,tags,mtime,frontmatter_json) VALUES(?,?,'note','x',?,'',0,'{}')",
                               arguments: [path, title, body])
                let rid = try Int64.fetchOne(db, sql: "SELECT rowid FROM pages WHERE path=?", arguments: [path])!
                try db.execute(sql: "INSERT INTO pages_fts(rowid,title,body,tags) VALUES(?,?,?,'')",
                               arguments: [rid, title, body])
            }
        }
        let store = EmbeddingStore(dbQueue: index.dbQueue)
        try await store.upsert(path: "/v/cars.md", vector: [1, 0], model: "m")
        try await store.upsert(path: "/v/food.md", vector: [0, 1], model: "m")

        let search = KBSearch(dbQueue: index.dbQueue)
        // Query vector points at "cars"; query TEXT ("vehicle") matches no body lexically.
        let hits = await search.hybridSearch("vehicle", queryVector: [1, 0],
                                             vectors: try await store.loadAll(), limit: 2)
        XCTAssertEqual(hits.first?.page.path, "/v/cars.md",
                       "dense similarity surfaces the semantic match BM25 alone misses")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/HybridSearchTests`
Expected: FAIL — `hybridSearch` undefined.

- [ ] **Step 3: Add `hybridSearch` to `KBSearch`** (keep the existing `search` as the BM25-only fallback):

```swift
    /// Hybrid retrieval: fuse the BM25 ranking with a dense cosine ranking via RRF.
    /// `vectors` is the in-memory path→vector map (EmbeddingStore.loadAll); `queryVector`
    /// is the embedded query. If `vectors` is empty this degrades to BM25-only.
    func hybridSearch(_ query: String, queryVector: [Float],
                      vectors: [String: [Float]], limit: Int) async -> [KBHit] {
        // 1. BM25 ranked paths (reuse existing FTS path; take a generous candidate depth).
        let bmHits = await search(query, limit: 50)
        let bmRanked = bmHits.map(\.page.path)

        // 2. Dense ranked paths by cosine to the query vector.
        let denseRanked = vectors
            .map { (path: $0.key, sim: VectorMath.cosine(queryVector, $0.value)) }
            .sorted { $0.sim > $1.sim }
            .prefix(50)
            .map(\.path)

        // 3. RRF fuse; if there are no vectors, RRF over [bmRanked] == BM25 order.
        let fused = RankFusion.rrf([bmRanked, Array(denseRanked)], k: 60)

        // 4. Re-hydrate KBPage for the fused top-`limit` (load from pages by path).
        let top = Array(fused.prefix(limit))
        let pages: [String: KBPage] = (try? await dbQueue.read { db -> [String: KBPage] in
            guard !top.isEmpty else { return [:] }
            let qs = top.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE path IN (\(qs))",
                                    arguments: StatementArguments(top))
                .reduce(into: [:]) { $0[$1["path"] as String] = KBPage(brainRow: $1) }
        }) ?? [:]
        // Preserve fused order; score is the reciprocal-rank position (descending).
        return top.enumerated().compactMap { idx, path in
            pages[path].map { KBHit(page: $0, score: 1.0 / Double(idx + 1)) }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/HybridSearchTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/KBSearch.swift LocalpenTests/HybridSearchTests.swift
git commit -m "feat(brain): hybrid BM25+dense retrieval via RRF (BM25-only fallback preserved)"
```

---

## Task 8: Wire hybrid into the ask path + gold-set sanity check

**Files:**
- Modify: the ContextEngine / caller that currently invokes `KBSearch.search` (find via `grep -rn "\.search(" Localpen/Services/Brain Localpen/Services/*ContextEngine* ` — wire it to embed the query (EmbeddingService) + load vectors (EmbeddingStore.loadAll) + call `hybridSearch`, falling back to `search` if the embedding server is down).

- [ ] **Step 1:** Locate the caller, inject `EmbeddingService` + the loaded vector map, switch to `hybridSearch`. Keep a guard: if `vectors.isEmpty` or embedding throws, call the existing `search` (no regression when embeddings absent).

- [ ] **Step 2: Gold-set sanity check (manual, the honest gate).** Create `LocalpenTests/Fixtures/retrieval_goldset.json` with ~20 real `{query, expectedPath}` pairs from your vault. Add a test that builds the live brain over the real vault, runs both `search` and `hybridSearch`, and prints Recall@5 + MRR for each. Assert hybrid Recall@5 ≥ BM25 Recall@5 (non-regression). This is the ADR-0023 / spec success criterion — measured, not asserted.

- [ ] **Step 3: Verify**

Run the full suite: `xcodebuild test -scheme Localpen -destination 'platform=macOS'`
Expected: all green; the gold-set test prints hybrid ≥ BM25 on Recall@5.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(brain): route ask retrieval through hybrid search; gold-set recall gate"
```

---

## Self-review notes (done while writing)

- **Spec coverage:** EmbeddingGemma + dim/pooling/prefix contract (Task 4) ✓; sqlite storage without sqlite-vec (Task 3) ✓; RRF fusion replacing the score seam (Tasks 2, 7) ✓; BM25 fallback when embeddings absent (Tasks 6, 7, 8) ✓; measured Recall gate (Task 8) ✓; reranker = deferred (out of scope this branch — add behind the gold-set gate later, matching cx-news's "deferred behind eval" stance).
- **Type consistency:** `EmbeddingService.modelID/dim`, `EmbeddingStore(dbQueue:)` `.upsert/.loadAll/.unembeddedPaths`, `VectorMath.cosine/.data/.floats`, `RankFusion.rrf`, `KBSearch.hybridSearch` — names used consistently across tasks. `BrainIndex.dbQueue` is `let` (public) per the source.
- **Open item (flagged, not a placeholder):** Task 5 model acquisition is a real human decision (download flow vs hand-placed GGUF) — called out explicitly so the agent escalates rather than inventing a downloader.
- **Reranker** (bge-reranker-v2-m3) intentionally omitted from v1 — diminishing returns at this candidate depth (per research); add only if the gold-set shows top-k precision is the bottleneck.
