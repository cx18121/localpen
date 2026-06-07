# Voice Data Exporter (feat/voice-data-exporter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the dataset for voice fine-tuning (workstream A, part 1): export a blended JSONL from (a) the user's accepted in-place edits in `history.sqlite` as instruction→output pairs and (b) the cxkb prose as raw-text samples, with a held-out split. No training, no model — just the data pipeline. Read-only on existing stores.

**Architecture:** A pure `VoiceDataExporter` (injectable `DatabaseQueue` for the interactions DB + a vault `URL`) produces `TrainingExample` rows from accepted transform interactions, plus prose chunks from the vault, then blends + splits them into train/heldout JSONL strings. A new `localpen export-voice-data` CLI subcommand wires the real paths and writes the files.

**Tech Stack:** Swift, GRDB (existing `history.sqlite`), XCTest. Fully independent of the ML/diff branches.

**Branch:** `feat/voice-data-exporter` off current `main`.

**Schema reference (verified, `interactions` table):** `timestamp, source_app, selection, action, custom_prompt, model_id, model_output, accepted, edited_output, thread_id`. Accepted final text = `edited_output` if non-empty else `model_output` (mirrors `acceptResult()`).

---

## File structure

- **Create** `Localpen/Services/Memory/VoiceDataExporter.swift` — pure exporter (DB→pairs, vault→prose, blend/split, JSONL). Target membership: **Localpen app AND localpen-cli** (the CLI calls it).
- **Modify** `LocalpenCLI/main.swift` — add the `export-voice-data` subcommand + usage line.
- **Tests** `LocalpenTests/VoiceDataExporterTests.swift`.

---

## Task 0: Branch

- [ ] **Step 1**

```bash
cd /Users/charliexue/School/cs_misc/localpen
git checkout main && git pull --ff-only 2>/dev/null; git checkout -b feat/voice-data-exporter
```

---

## Task 1: instruction pairs from accepted edits

**Files:**
- Create: `Localpen/Services/Memory/VoiceDataExporter.swift`
- Test: `LocalpenTests/VoiceDataExporterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import GRDB
@testable import Localpen

final class VoiceDataExporterTests: XCTestCase {
    /// Minimal interactions table with just the columns the exporter reads.
    private func seededDB(_ rows: [(action: String, sel: String?, custom: String?,
                                    out: String?, edited: String?, accepted: Int)]) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try q.write { db in
            try db.execute(sql: """
                CREATE TABLE interactions(
                  id INTEGER PRIMARY KEY, action TEXT, selection TEXT, custom_prompt TEXT,
                  model_output TEXT, edited_output TEXT, accepted INTEGER NOT NULL)
                """)
            for r in rows {
                try db.execute(sql: "INSERT INTO interactions(action,selection,custom_prompt,model_output,edited_output,accepted) VALUES(?,?,?,?,?,?)",
                               arguments: [r.action, r.sel, r.custom, r.out, r.edited, r.accepted])
            }
        }
        return q
    }

    func test_proofread_pair_usesMappedInstruction_andEditedOutput() async throws {
        let db = try seededDB([("proofread", "i has cat", nil, "I has cat", "I have a cat.", 1)])
        let pairs = try await VoiceDataExporter.instructionPairs(db: db)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].input, "i has cat")
        XCTAssertEqual(pairs[0].output, "I have a cat.", "edited_output is the gold label, not model_output")
        XCTAssertTrue(pairs[0].instruction.localizedCaseInsensitiveContains("proofread"))
    }
    func test_fallsBackToModelOutputWhenNoEdit() async throws {
        let db = try seededDB([("polish", "rough draft", nil, "Polished draft.", nil, 1)])
        let pairs = try await VoiceDataExporter.instructionPairs(db: db)
        XCTAssertEqual(pairs.first?.output, "Polished draft.")
    }
    func test_skipsUnacceptedAndCreateActions() async throws {
        let db = try seededDB([
            ("polish", "x", nil, "y", nil, 0),                 // not accepted
            ("respond", "their msg", "be nice", "my reply", nil, 1), // create action — excluded
            ("ask", "ctx", "what is x", "answer", nil, 1),     // create — excluded
        ])
        let pairs = try await VoiceDataExporter.instructionPairs(db: db)
        XCTAssertTrue(pairs.isEmpty, "only accepted in-place transforms become voice pairs")
    }
    func test_customUsesUserInstruction() async throws {
        let db = try seededDB([("custom", "make it rhyme", "make this rhyme", "rhymed text", nil, 1)])
        let pairs = try await VoiceDataExporter.instructionPairs(db: db)
        XCTAssertEqual(pairs.first?.instruction, "make this rhyme", "custom uses the user's own instruction")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests`
Expected: FAIL — `VoiceDataExporter` undefined.

- [ ] **Step 3: Write the implementation** (instruction-pairs portion)

```swift
import Foundation
import GRDB

/// Builds voice fine-tuning data from the user's own writing: accepted in-place edits
/// (instruction→output pairs) + cxkb prose (raw text). Pure + injectable so it's
/// testable without the live stores. No training here — just the dataset.
enum VoiceDataExporter {
    struct TrainingExample: Codable, Equatable {
        let instruction: String
        let input: String      // "" for raw-prose samples
        let output: String
    }

    /// In-place transform actions only — these are genuine "the user rewrites text in
    /// their voice" signal. respond/ask are excluded: their selection is third-party and
    /// their output is model-composed (drift), matching MemoryAttribution's policy.
    static func instruction(for action: String, customPrompt: String?) -> String? {
        switch action {
        case "proofread":   return "Proofread this text, fixing grammar, spelling, and punctuation."
        case "polish":      return "Polish this text."
        case "more_formal": return "Rewrite this text in a more formal tone."
        case "more_casual": return "Rewrite this text in a more casual tone."
        case "shorter":     return "Make this text shorter."
        case "custom":
            let c = (customPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? nil : c          // custom uses the user's own instruction
        default:            return nil           // respond/ask/etc. excluded
        }
    }

    static func instructionPairs(db: DatabaseQueue) async throws -> [TrainingExample] {
        let rows = try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT action, selection, custom_prompt,
                       CASE WHEN edited_output IS NOT NULL AND length(edited_output) > 0
                            THEN edited_output ELSE model_output END AS final
                FROM interactions
                WHERE accepted = 1
                  AND selection IS NOT NULL AND length(selection) > 0
                """)
        }
        return rows.compactMap { row in
            guard let instr = instruction(for: row["action"], customPrompt: row["custom_prompt"]),
                  let input: String = row["selection"],
                  let output: String = row["final"], !output.isEmpty else { return nil }
            return TrainingExample(instruction: instr, input: input, output: output)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Memory/VoiceDataExporter.swift LocalpenTests/VoiceDataExporterTests.swift
git commit -m "feat(A): VoiceDataExporter — instruction pairs from accepted in-place edits"
```

---

## Task 2: prose chunks from the vault

**Files:**
- Modify: `Localpen/Services/Memory/VoiceDataExporter.swift`
- Test: `LocalpenTests/VoiceDataExporterTests.swift` (add)

- [ ] **Step 1: Write the failing test** (add to the test file)

```swift
    func test_proseChunks_stripFrontmatterAndChunk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = "---\ntype: note\n---\n\nFirst paragraph.\n\nSecond paragraph."
        try md.write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let chunks = VoiceDataExporter.proseChunks(vaultRoot: dir, maxChars: 1000)
        XCTAssertFalse(chunks.contains { $0.contains("type: note") }, "frontmatter stripped")
        XCTAssertTrue(chunks.contains { $0.contains("First paragraph") })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests/test_proseChunks_stripFrontmatterAndChunk`
Expected: FAIL — `proseChunks` undefined.

- [ ] **Step 3: Implement** (add to `VoiceDataExporter`) — reuse the existing static helpers `BrainIndex.enumerateMarkdown` + `MarkdownParser.splitFrontmatter`:

```swift
    /// Raw-prose samples from the vault: frontmatter-stripped bodies, paragraph-packed
    /// into ~`maxChars` chunks. Excludes the usual non-content dirs (.obsidian/.git/raw).
    static func proseChunks(vaultRoot: URL, maxChars: Int = 1500) -> [String] {
        let excluded: Set<String> = [".obsidian", ".git", "raw"]
        var out: [String] = []
        for url in BrainIndex.enumerateMarkdown(root: vaultRoot, excluding: excluded) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let body = MarkdownParser.splitFrontmatter(raw).body
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var buf = ""
            for para in body.components(separatedBy: "\n\n") {
                let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.isEmpty { continue }
                if buf.count + p.count > maxChars, !buf.isEmpty { out.append(buf); buf = "" }
                buf += buf.isEmpty ? p : "\n\n" + p
            }
            if !buf.isEmpty { out.append(buf) }
        }
        return out
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Memory/VoiceDataExporter.swift LocalpenTests/VoiceDataExporterTests.swift
git commit -m "feat(A): VoiceDataExporter — cxkb prose chunks (frontmatter-stripped)"
```

---

## Task 3: blend + deterministic train/heldout split → JSONL

**Files:**
- Modify: `Localpen/Services/Memory/VoiceDataExporter.swift`
- Test: `LocalpenTests/VoiceDataExporterTests.swift` (add)

- [ ] **Step 1: Write the failing test**

```swift
    func test_jsonl_blendsAndHoldsOut() throws {
        let pairs = (0..<8).map { VoiceDataExporter.TrainingExample(instruction: "Polish this text.", input: "in\($0)", output: "out\($0)") }
        let prose = (0..<2).map { "prose body \($0)" }
        let (train, heldout) = VoiceDataExporter.jsonl(pairs: pairs, prose: prose, holdoutEvery: 5)
        let trainLines = train.split(separator: "\n").count
        let heldLines = heldout.split(separator: "\n").count
        XCTAssertEqual(trainLines + heldLines, 10, "every example lands in exactly one split")
        XCTAssertGreaterThan(heldLines, 0, "a non-empty holdout exists")
        // prose rows have empty input
        XCTAssertTrue(train.contains(#""input":"""#) || heldout.contains(#""input":"""#))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests/test_jsonl_blendsAndHoldsOut`
Expected: FAIL — `jsonl` undefined.

- [ ] **Step 3: Implement** (add to `VoiceDataExporter`)

```swift
    /// Blend instruction pairs + prose (as empty-input examples) into one list, then
    /// split deterministically (every Nth row → holdout). Deterministic on purpose:
    /// Math.random/Date are unavailable in some contexts and reproducibility matters.
    static func jsonl(pairs: [TrainingExample], prose: [String],
                      holdoutEvery: Int = 8) -> (train: String, heldout: String) {
        let proseExamples = prose.map { TrainingExample(instruction: "Continue in the user's voice.", input: "", output: $0) }
        let all = pairs + proseExamples
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
        var train: [String] = [], held: [String] = []
        for (i, ex) in all.enumerated() {
            guard let data = try? enc.encode(ex), let line = String(data: data, encoding: .utf8) else { continue }
            if holdoutEvery > 0 && i % holdoutEvery == (holdoutEvery - 1) { held.append(line) } else { train.append(line) }
        }
        return (train.joined(separator: "\n"), held.joined(separator: "\n"))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VoiceDataExporterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Memory/VoiceDataExporter.swift LocalpenTests/VoiceDataExporterTests.swift
git commit -m "feat(A): VoiceDataExporter — blend + deterministic holdout split to JSONL"
```

---

## Task 4: CLI subcommand `export-voice-data`

**Files:**
- Modify: `LocalpenCLI/main.swift`

- [ ] **Step 1: Add the subcommand.** In the `switch command` block (after `case "project":`), add:

```swift
case "export-voice-data":
    // Read interactions from history.sqlite (read-only) + prose from the vault;
    // write train.jsonl + heldout.jsonl to the output dir (arg, else cwd).
    let outDir = argument.isEmpty
        ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        : URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
    let historyURL = AppSupport.root().appendingPathComponent("history.sqlite")
    var cfg = Configuration(); cfg.readonly = true
    guard let hq = try? DatabaseQueue(path: historyURL.path, configuration: cfg) else {
        fail("could not open history.sqlite at \(historyURL.path)")
    }
    let pairs = (try? await VoiceDataExporter.instructionPairs(db: hq)) ?? []
    let prose = VoiceDataExporter.proseChunks(vaultRoot: vaultRoot)
    let (train, held) = VoiceDataExporter.jsonl(pairs: pairs, prose: prose)
    try? train.write(to: outDir.appendingPathComponent("voice_train.jsonl"), atomically: true, encoding: .utf8)
    try? held.write(to: outDir.appendingPathComponent("voice_heldout.jsonl"), atomically: true, encoding: .utf8)
    warn("exported \(pairs.count) edit pairs + \(prose.count) prose chunks → \(outDir.path)")
```

- [ ] **Step 2: Add the usage line** in `printUsage()`:

```swift
      localpen export-voice-data [<out-dir>]   (voice fine-tuning JSONL from edits + cxkb)
```

- [ ] **Step 3: Build + smoke test**

Run: `xcodebuild build -scheme localpen-cli -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.
Then (manual): run the built `localpen export-voice-data /tmp/vd` and confirm `voice_train.jsonl` + `voice_heldout.jsonl` exist and contain valid JSON lines (`head -1 /tmp/vd/voice_train.jsonl`).

- [ ] **Step 4: Commit**

```bash
git add LocalpenCLI/main.swift
git commit -m "feat(A): localpen export-voice-data — write blended voice JSONL from edits + cxkb"
```

---

## Notes / self-review
- **`VoiceDataExporter` must be in both targets** — if the CLI build can't see it, add it to the `localpen-cli` target membership in `project.yml` (the CLI already shares app sources like `BrainIndex`). Verify Task 4 builds.
- **`AppSupport`, `Configuration`, `BrainIndex.enumerateMarkdown`, `MarkdownParser.splitFrontmatter`** are all existing symbols the CLI/app already use — no new deps.
- **Excludes respond/ask by design** (create actions; their text isn't the user's in-place voice) — matches `MemoryAttribution`'s "never train on model-composed output" rule.
- **Read-only** on `history.sqlite` (Configuration.readonly) — the exporter never mutates the interaction store.
- **Out of scope:** the actual LoRA training (Unsloth/cloud), GGUF conversion, serving the adapter — that's workstream A part 2, a separate plan once the dataset looks right.
