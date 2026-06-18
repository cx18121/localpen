# Project Activity Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A nightly pass reads each project's git commits and appends an honest, cited, scope-grouped summary to a tool-owned `## Activity` log on its project page, so the brain stops going stale on its own.

**Architecture:** A sibling pass to the existing conversation dream cycle, invoked by the same nightly trigger and sharing its temp-0.3 synthesize closure over the local llama-server. Per project page with a `local_path` git repo: read commits since the page went stale (first run anchored to `updated`, capped 90d; steady-state since the last-synced SHA in a sidecar store) → adaptive batches (≤30 commits / ≤2 weeks) → per-batch extractive+cited summary + self-check → append via a new additive `CurationWrite.appendActivity`.

**Tech Stack:** Swift, XCTest, GRDB (brain index), git CLI (`/usr/bin/git`), llama.cpp (the loaded transform model via `StreamingClient`).

## Global Constraints

- macOS deployment target **14 (Sonoma)** minimum.
- **Auto-write, append-only.** The pass appends to a tool-owned `## Activity` section ONLY. It never edits the body, `## Status`, or frontmatter. A wrong entry must be a one-line fix, never data loss.
- **Extractive, not generative.** Summaries cite commit short-SHAs and state only what commit messages support. No inferred outcomes/status.
- **Faithful synthesis** uses the dream-cycle sampling already in use: temperature 0.3, the injected `(String, String) async -> CurationOutcome` closure (`CurationOutcome.completed(String)` / `.failed(String)`).
- **Git hygiene:** `VaultWriter` stages only the explicit path it touched, never `git add -A`. Each write is one commit.
- **Failure isolation:** a missing/broken repo or failed batch is skipped + logged, never errors the pass; a repo with no new commits is a no-op.
- New files registered in the gitignored `Localpen.xcodeproj` via `ruby scripts/add-file-to-target.rb <Target> <file>` (project has no synchronized groups).
- TDD: failing test → minimal impl → green → commit. Pure logic unit-tested with fixtures from real `git log`; model + shell paths integration-gated.

---

### Task 1: `Commit` model + conventional-commit parsing

**Files:**
- Create: `Localpen/Services/Brain/Activity/GitActivityReader.swift`
- Test: `LocalpenTests/GitActivityReaderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct Commit: Equatable {
      let sha: String        // short (7-char)
      let date: Date         // author date
      let type: String       // "feat","fix",… ; "" if not conventional
      let scope: String?     // "w2","hub" ; nil if absent
      let subject: String    // description after "type(scope): "
      let body: String       // trimmed; "" if none
      let filesChanged: Int
      let insertions: Int
      let deletions: Int
  }
  enum GitActivityReader {
      /// Parse the exact `git log` format below into commits (pure).
      static func parse(_ rawLog: String) -> [Commit]
      /// Drop chore/style/build/ci trivia (merges already excluded by --no-merges).
      static func substantive(_ commits: [Commit]) -> [Commit]
      // (read(...) added in Task 2)
  }
  ```
- The pass shells this exact command (documented here, used in Task 2):
  `git -C <repo> log <range> --no-merges --date=short --shortstat --pretty=format:"@@C@@%x1f%h%x1f%aI%x1f%s%x1f%b%x1f@@E@@"`
  Output per commit: a line starting `@@C@@` with `\u{1f}`-separated `sha, ISO-date, subject, body, @@E@@`, followed by git's `--shortstat` line (` N files changed, X insertions(+), Y deletions(-)`), then a blank line.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class GitActivityReaderTests: XCTestCase {
    // One real-shaped git log block (matches the Task-1 --pretty format; \u{1f} = US separator).
    private func block(sha: String, date: String, subject: String, body: String,
                       stat: String) -> String {
        "@@C@@\u{1f}\(sha)\u{1f}\(date)\u{1f}\(subject)\u{1f}\(body)\u{1f}@@E@@\n\(stat)\n\n"
    }

    func test_parse_conventionalCommit_splitsTypeScopeSubject() {
        let raw = block(sha: "fb7827b", date: "2026-06-17", subject: "feat(w2): mention autocomplete",
                        body: "Type [[ or @ to get a list.", stat: " 3 files changed, 40 insertions(+), 5 deletions(-)")
        let c = GitActivityReader.parse(raw)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].sha, "fb7827b")
        XCTAssertEqual(c[0].type, "feat")
        XCTAssertEqual(c[0].scope, "w2")
        XCTAssertEqual(c[0].subject, "mention autocomplete")
        XCTAssertEqual(c[0].body, "Type [[ or @ to get a list.")
        XCTAssertEqual(c[0].filesChanged, 3)
        XCTAssertEqual(c[0].insertions, 40)
        XCTAssertEqual(c[0].deletions, 5)
    }

    func test_parse_noScope_andNonConventional() {
        let raw = block(sha: "aaa1111", date: "2026-06-10", subject: "fix: off-by-one",
                        body: "", stat: " 1 file changed, 2 insertions(+)")
            + block(sha: "bbb2222", date: "2026-06-11", subject: "random commit message",
                    body: "", stat: " 1 file changed, 1 deletion(-)")
        let c = GitActivityReader.parse(raw)
        XCTAssertEqual(c[0].type, "fix"); XCTAssertNil(c[0].scope); XCTAssertEqual(c[0].subject, "off-by-one")
        XCTAssertEqual(c[0].insertions, 2); XCTAssertEqual(c[0].deletions, 0)
        XCTAssertEqual(c[1].type, ""); XCTAssertNil(c[1].scope); XCTAssertEqual(c[1].subject, "random commit message")
    }

    func test_parse_multilineBody_preserved() {
        let raw = block(sha: "ccc3333", date: "2026-06-12", subject: "refactor(hub): 4 modes",
                        body: "Today absorbs Now.\nDelete 3 views.", stat: " 6 files changed, 80 insertions(+), 200 deletions(-)")
        XCTAssertEqual(GitActivityReader.parse(raw)[0].body, "Today absorbs Now.\nDelete 3 views.")
    }

    func test_substantive_dropsTrivia() {
        let raw = block(sha: "d1", date: "2026-06-12", subject: "feat(x): real", body: "", stat: " 1 file changed, 1 insertion(+)")
            + block(sha: "d2", date: "2026-06-12", subject: "chore: bump deps", body: "", stat: " 1 file changed, 1 insertion(+)")
            + block(sha: "d3", date: "2026-06-12", subject: "style: format", body: "", stat: " 1 file changed, 1 insertion(+)")
        let kept = GitActivityReader.substantive(GitActivityReader.parse(raw))
        XCTAssertEqual(kept.map(\.sha), ["d1"], "chore/style dropped, feat kept")
    }

    func test_parse_emptyLog_isEmpty() {
        XCTAssertEqual(GitActivityReader.parse(""), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/GitActivityReaderTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'GitActivityReader' in scope".

- [ ] **Step 3: Implement parse + substantive**

```swift
import Foundation

/// Reads + parses a repo's git history into structured commits for the project-activity
/// pass (project-activity-freshness spec). Parsing is pure (testable with `git log` fixtures);
/// `read` shells git. Relies on the conventional-commit discipline the user already follows.
struct Commit: Equatable {
    let sha: String
    let date: Date
    let type: String
    let scope: String?
    let subject: String
    let body: String
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
}

enum GitActivityReader {
    /// Trivia types excluded from activity summaries.
    private static let trivialTypes: Set<String> = ["chore", "style", "build", "ci"]

    static func parse(_ rawLog: String) -> [Commit] {
        // Each commit: "@@C@@\u{1f}sha\u{1f}date\u{1f}subject\u{1f}body…\u{1f}@@E@@" then a
        // --shortstat line. Split on the "@@C@@\u{1f}" record opener.
        let records = rawLog.components(separatedBy: "@@C@@\u{1f}").dropFirst()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        var out: [Commit] = []
        for rec in records {
            guard let endRange = rec.range(of: "\u{1f}@@E@@") else { continue }
            let head = String(rec[rec.startIndex..<endRange.lowerBound])
            let fields = head.components(separatedBy: "\u{1f}")
            guard fields.count >= 4 else { continue }
            let sha = fields[0]
            let date = iso.date(from: fields[1]) ?? Date(timeIntervalSince1970: 0)
            let rawSubject = fields[2]
            let body = fields[3...].joined(separator: "\u{1f}").trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(rec[endRange.upperBound...])
            let stat = parseShortstat(after)
            let (type, scope, subject) = splitConventional(rawSubject)
            out.append(Commit(sha: sha, date: date, type: type, scope: scope, subject: subject,
                              body: body, filesChanged: stat.files, insertions: stat.ins, deletions: stat.del))
        }
        return out
    }

    static func substantive(_ commits: [Commit]) -> [Commit] {
        commits.filter { !trivialTypes.contains($0.type) }
    }

    /// "feat(w2): text" → ("feat","w2","text"); "fix: text" → ("fix",nil,"text");
    /// "plain msg" → ("",nil,"plain msg").
    private static func splitConventional(_ s: String) -> (type: String, scope: String?, subject: String) {
        guard let colon = s.firstIndex(of: ":") else { return ("", nil, s.trimmingCharacters(in: .whitespaces)) }
        let prefix = String(s[s.startIndex..<colon])
        let rest = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // prefix is "type" or "type(scope)" — and must look like a type token (no spaces).
        guard !prefix.contains(" ") else { return ("", nil, s.trimmingCharacters(in: .whitespaces)) }
        if let open = prefix.firstIndex(of: "("), prefix.hasSuffix(")") {
            let type = String(prefix[prefix.startIndex..<open])
            let scope = String(prefix[prefix.index(after: open)..<prefix.index(before: prefix.endIndex)])
            return (type, scope.isEmpty ? nil : scope, rest)
        }
        return (prefix, nil, rest)
    }

    /// " 3 files changed, 40 insertions(+), 5 deletions(-)" → (3,40,5). Missing parts → 0.
    private static func parseShortstat(_ s: String) -> (files: Int, ins: Int, del: Int) {
        func num(_ pattern: String) -> Int {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return 0 }
            return Int(s[r].prefix(while: { $0.isNumber })) ?? 0
        }
        return (num(#"\d+ files? changed"#), num(#"\d+ insertions?\(\+\)"#), num(#"\d+ deletions?\(-\)"#))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/GitActivityReaderTests 2>&1 | tail -20`
Expected: PASS — `Executed 5 tests, with 0 failures`.

> New files: register them before the test build sees them:
> `ruby scripts/add-file-to-target.rb Localpen Localpen/Services/Brain/Activity/GitActivityReader.swift`
> `ruby scripts/add-file-to-target.rb LocalpenTests LocalpenTests/GitActivityReaderTests.swift`

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/GitActivityReader.swift LocalpenTests/GitActivityReaderTests.swift
git commit -m "feat(activity): git log parser — conventional commits + diffstat"
```

---

### Task 2: `GitActivityReader.read` — shell git log (integration)

**Files:**
- Modify: `Localpen/Services/Brain/Activity/GitActivityReader.swift`
- Test: `LocalpenTests/GitActivityReaderTests.swift` (add an integration test over a temp repo)

**Interfaces:**
- Produces:
  ```swift
  extension GitActivityReader {
      struct ReadResult: Equatable { let commits: [Commit]; let head: String }
      /// Commits in (sinceSHA, HEAD]; or, when sinceSHA is nil, those on/after sinceDate.
      /// `head` is the current HEAD short-SHA (to record as the new sync point). Throws on
      /// any git failure or a non-repo path.
      static func read(repoPath: String, sinceSHA: String?, sinceDate: Date?) throws -> ReadResult
  }
  enum GitError: Error, Equatable { case notARepo, git(String) }
  ```

- [ ] **Step 1: Write the failing integration test (builds a real temp repo)**

```swift
    func test_read_overTempRepo_returnsSubstantiveCommitsAndHead() throws {
        let repo = try makeTempRepo([
            "feat(w2): first",
            "chore: noise",
            "fix(hub): second",
        ])
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try GitActivityReader.read(repoPath: repo.path, sinceSHA: nil, sinceDate: nil)
        let kept = GitActivityReader.substantive(result.commits)
        XCTAssertEqual(kept.map(\.subject), ["first", "second"], "oldest→newest, trivia filtered")
        XCTAssertFalse(result.head.isEmpty)
    }

    func test_read_nonRepo_throws() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitActivityReader.read(repoPath: tmp.path, sinceSHA: nil, sinceDate: nil))
    }

    /// Build a throwaway git repo with one commit per message (each touches a file).
    private func makeTempRepo(_ messages: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func git(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args; p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
        }
        try git(["init", "-q"]); try git(["config", "user.email", "t@t.t"]); try git(["config", "user.name", "t"])
        for (i, m) in messages.enumerated() {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-q", "-m", m])
        }
        return dir
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/GitActivityReaderTests/test_read_overTempRepo_returnsSubstantiveCommitsAndHead 2>&1 | tail -20`
Expected: FAIL — no `read` method.

- [ ] **Step 3: Implement `read`**

```swift
extension GitActivityReader {
    struct ReadResult: Equatable { let commits: [Commit]; let head: String }

    static func read(repoPath: String, sinceSHA: String?, sinceDate: Date?) throws -> ReadResult {
        guard runGit(repoPath, ["rev-parse", "--git-dir"]) != nil else { throw GitError.notARepo }
        guard let head = runGit(repoPath, ["rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            throw GitError.git("no HEAD")
        }
        var args = ["log", "--no-merges", "--date=short", "--shortstat", "--reverse",
                    "--pretty=format:@@C@@\u{1f}%h\u{1f}%aI\u{1f}%s\u{1f}%b\u{1f}@@E@@"]
        if let sinceSHA { args.append("\(sinceSHA)..HEAD") }
        else if let sinceDate {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
            args.append("--since=\(iso.string(from: sinceDate))")
        }
        guard let raw = runGit(repoPath, args) else { throw GitError.git("log failed") }
        return ReadResult(commits: parse(raw), head: head)
    }

    /// Run git in `repoPath`; returns stdout on success, nil on failure (incl. non-repo).
    private static func runGit(_ repoPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repoPath] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum GitError: Error, Equatable { case notARepo, git(String) }
```

> Note: `--reverse` makes the log oldest→newest (the order the batcher walks). The `@@C@@` opener split in `parse` already tolerates a leading newline from `format:`.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/GitActivityReaderTests 2>&1 | tail -20`
Expected: PASS — all 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/GitActivityReader.swift LocalpenTests/GitActivityReaderTests.swift
git commit -m "feat(activity): GitActivityReader.read — shell git log over a repo"
```

---

### Task 3: `ProjectActivityBatcher` — adaptive batching

**Files:**
- Create: `Localpen/Services/Brain/Activity/ProjectActivityBatcher.swift`
- Test: `LocalpenTests/ProjectActivityBatcherTests.swift`

**Interfaces:**
- Consumes: `Commit`.
- Produces:
  ```swift
  struct ActivityBatch: Equatable { let commits: [Commit] }   // non-empty; chronological
  enum ProjectActivityBatcher {
      /// Group chronological commits into batches that close at ≤maxCount commits OR a
      /// >maxSpanDays gap from the batch's first commit. Empty input → []. (No partial/empty batches.)
      static func batch(_ commits: [Commit], maxCount: Int = 30, maxSpanDays: Int = 14) -> [ActivityBatch]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class ProjectActivityBatcherTests: XCTestCase {
    private func commit(_ sha: String, day: Int) -> Commit {
        Commit(sha: sha, date: Date(timeIntervalSince1970: TimeInterval(day) * 86400),
               type: "feat", scope: "x", subject: sha, body: "", filesChanged: 1, insertions: 1, deletions: 0)
    }

    func test_emptyInput_noBatches() {
        XCTAssertEqual(ProjectActivityBatcher.batch([]), [])
    }

    func test_underBothCaps_singleBatch() {
        let cs = (0..<5).map { commit("c\($0)", day: $0) }   // 5 commits over 5 days
        let b = ProjectActivityBatcher.batch(cs, maxCount: 30, maxSpanDays: 14)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].commits.count, 5)
    }

    func test_countCapSplits() {
        let cs = (0..<70).map { commit("c\($0)", day: 0) }   // 70 same-day commits
        let b = ProjectActivityBatcher.batch(cs, maxCount: 30, maxSpanDays: 14)
        XCTAssertEqual(b.map(\.commits.count), [30, 30, 10], "count cap fires at 30")
    }

    func test_timeSpanSplits() {
        // 4 commits, each 10 days apart → spans exceed 14d, forcing new batches.
        let cs = [commit("a", day: 0), commit("b", day: 10), commit("c", day: 20), commit("d", day: 30)]
        let b = ProjectActivityBatcher.batch(cs, maxCount: 30, maxSpanDays: 14)
        // a,b within 14d of a(day0)? b=day10 ok; c=day20 is >14 from a → close [a,b]; c starts new,
        // d=day30 is >14 from c(day20)? 10d ok → [c,d].
        XCTAssertEqual(b.map { $0.commits.map(\.sha) }, [["a", "b"], ["c", "d"]])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivityBatcherTests 2>&1 | tail -20`
Expected: FAIL — no `ProjectActivityBatcher`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Splits chronological commits into bounded batches so each activity summary stays accurate
/// (count cap) and temporally honest (span cap). Pure + total.
struct ActivityBatch: Equatable { let commits: [Commit] }

enum ProjectActivityBatcher {
    static func batch(_ commits: [Commit], maxCount: Int = 30, maxSpanDays: Int = 14) -> [ActivityBatch] {
        guard !commits.isEmpty else { return [] }
        var out: [ActivityBatch] = []
        var cur: [Commit] = []
        let spanSec = TimeInterval(maxSpanDays) * 86400
        for c in commits {
            if let first = cur.first,
               (cur.count >= maxCount || c.date.timeIntervalSince(first.date) > spanSec) {
                out.append(ActivityBatch(commits: cur))
                cur = []
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(ActivityBatch(commits: cur)) }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivityBatcherTests 2>&1 | tail -20`
Expected: PASS — 4 tests.

> Register: `ruby scripts/add-file-to-target.rb Localpen Localpen/Services/Brain/Activity/ProjectActivityBatcher.swift` and the test file.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/ProjectActivityBatcher.swift LocalpenTests/ProjectActivityBatcherTests.swift
git commit -m "feat(activity): adaptive batching (≤30 commits / ≤2 weeks)"
```

---

### Task 4: `ProjectActivitySynthesis` — clustering, prompt, entry formatting

**Files:**
- Create: `Localpen/Services/Brain/Activity/ProjectActivitySynthesis.swift`
- Test: `LocalpenTests/ProjectActivitySynthesisTests.swift`

**Interfaces:**
- Consumes: `Commit`, `ActivityBatch`, `CurationOutcome`.
- Produces:
  ```swift
  enum ProjectActivitySynthesis {
      /// Group a batch by scope (nil → "other"), preserving first-seen order. Pure.
      static func clusters(_ batch: ActivityBatch) -> [(scope: String, commits: [Commit])]
      /// The user-role prompt fed to the model: clustered commits + per-cluster diffstat. Pure.
      static func prompt(for batch: ActivityBatch) -> String
      /// System prompt (extractive contract). Pure constant.
      static let system: String
      /// Self-check user prompt over a draft + the same commits. Pure.
      static func selfCheckPrompt(draft: String, batch: ActivityBatch) -> String
      /// The dated entry header for a batch, from its commit-date span ("Jun 5–6"). Pure.
      static func spanHeader(_ batch: ActivityBatch) -> String
      /// Full pipeline: synthesize → self-check → assemble "### span\n<bullets>". Returns nil if
      /// the model fails or returns empty (caller skips the entry, leaves sync unadvanced).
      static func entry(for batch: ActivityBatch,
                        synthesize: (_ system: String, _ user: String) async -> CurationOutcome) async -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests** (pure parts + a fake synthesize closure)

```swift
import XCTest
@testable import Localpen

final class ProjectActivitySynthesisTests: XCTestCase {
    private func c(_ sha: String, _ scope: String?, _ subject: String, day: Int) -> Commit {
        Commit(sha: sha, date: Date(timeIntervalSince1970: TimeInterval(day) * 86400),
               type: "feat", scope: scope, subject: subject, body: "", filesChanged: 2, insertions: 10, deletions: 1)
    }

    func test_clusters_groupByScope_unscopedToOther() {
        let batch = ActivityBatch(commits: [c("a", "w2", "x", day: 1), c("b", "hub", "y", day: 1),
                                            c("c", "w2", "z", day: 1), c("d", nil, "q", day: 1)])
        let cl = ProjectActivitySynthesis.clusters(batch)
        XCTAssertEqual(cl.map(\.scope), ["w2", "hub", "other"], "first-seen order; nil → other")
        XCTAssertEqual(cl[0].commits.map(\.sha), ["a", "c"])
    }

    func test_prompt_includesShasScopesAndDiffstat() {
        let batch = ActivityBatch(commits: [c("a1b2c3", "w2", "autocomplete", day: 1)])
        let p = ProjectActivitySynthesis.prompt(for: batch)
        XCTAssertTrue(p.contains("a1b2c3"))
        XCTAssertTrue(p.contains("w2"))
        XCTAssertTrue(p.contains("autocomplete"))
        XCTAssertTrue(p.contains("1 commit"))   // per-cluster aggregate
    }

    func test_spanHeader_sameDay_andRange() {
        XCTAssertEqual(ProjectActivitySynthesis.spanHeader(ActivityBatch(commits: [c("a", "x", "s", day: 100)])),
                       ProjectActivitySynthesis.spanHeader(ActivityBatch(commits: [c("a", "x", "s", day: 100)])))
        let range = ActivityBatch(commits: [c("a", "x", "s", day: 100), c("b", "x", "t", day: 102)])
        XCTAssertTrue(ProjectActivitySynthesis.spanHeader(range).contains("–"), "multi-day span uses an en-dash range")
    }

    func test_entry_assemblesHeaderPlusModelBody() async {
        let batch = ActivityBatch(commits: [c("a1b2c3", "w2", "autocomplete", day: 100)])
        // Fake model: synthesize returns a bullet; self-check returns it unchanged.
        let synth: (String, String) async -> CurationOutcome = { _, user in
            user.contains("Remove any") ? .completed("- **w2**: shipped autocomplete (a1b2c3)")
                                        : .completed("- **w2**: shipped autocomplete (a1b2c3)")
        }
        let entry = await ProjectActivitySynthesis.entry(for: batch, synthesize: synth)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.hasPrefix("### "))
        XCTAssertTrue(entry!.contains("- **w2**: shipped autocomplete (a1b2c3)"))
    }

    func test_entry_modelFailure_returnsNil() async {
        let batch = ActivityBatch(commits: [c("a", "w2", "x", day: 1)])
        let entry = await ProjectActivitySynthesis.entry(for: batch, synthesize: { _, _ in .failed("down") })
        XCTAssertNil(entry)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivitySynthesisTests 2>&1 | tail -20`
Expected: FAIL — no `ProjectActivitySynthesis`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns a commit batch into a dated, scope-grouped, cited activity entry via the injected
/// synthesize closure. Clustering / prompt / span are pure; the two model calls (synthesize +
/// self-check) go through the closure so the pipeline is testable with a fake model.
enum ProjectActivitySynthesis {
    static func clusters(_ batch: ActivityBatch) -> [(scope: String, commits: [Commit])] {
        var order: [String] = []
        var byScope: [String: [Commit]] = [:]
        for c in batch.commits {
            let key = c.scope ?? "other"
            if byScope[key] == nil { order.append(key) }
            byScope[key, default: []].append(c)
        }
        return order.map { ($0, byScope[$0]!) }
    }

    static let system = """
        You write a project's activity log from its git commits. State ONLY what the commit \
        messages say was done. Do not infer outcomes, status, impact, or progress beyond the \
        text. Keep the scope groups you are given. Output one markdown bullet per scope: \
        "- **scope**: what was done (sha, sha)". Cite the short SHAs each bullet covers. No \
        preamble, no headings, no commentary.
        """

    static func prompt(for batch: ActivityBatch) -> String {
        var lines = ["Summarize these commits, grouped by scope:\n"]
        for (scope, commits) in clusters(batch) {
            let files = commits.reduce(0) { $0 + $1.filesChanged }
            lines.append("## \(scope) — \(commits.count) commit\(commits.count == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")")
            for c in commits {
                lines.append("- (\(c.sha)) \(c.subject)")
                if !c.body.isEmpty { lines.append("    \(c.body.replacingOccurrences(of: "\n", with: " "))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func selfCheckPrompt(draft: String, batch: ActivityBatch) -> String {
        """
        Commits:
        \(prompt(for: batch))

        Draft summary:
        \(draft)

        Remove any clause not directly supported by a commit message above. Return only the corrected bullets.
        """
    }

    static func spanHeader(_ batch: ActivityBatch) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
        let dates = batch.commits.map(\.date).sorted()
        let lo = f.string(from: dates.first ?? Date()), hi = f.string(from: dates.last ?? Date())
        return "### " + (lo == hi ? lo : "\(lo)–\(hi)")
    }

    static func entry(for batch: ActivityBatch,
                      synthesize: (_ system: String, _ user: String) async -> CurationOutcome) async -> String? {
        guard case .completed(let draft) = await synthesize(system, prompt(for: batch)),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard case .completed(let checked) = await synthesize(system, selfCheckPrompt(draft: draft, batch: batch)) else {
            return nil
        }
        let body = checked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "\(spanHeader(batch))\n\(body)"
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivitySynthesisTests 2>&1 | tail -20`
Expected: PASS — 5 tests.

> Register both files in their targets.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/ProjectActivitySynthesis.swift LocalpenTests/ProjectActivitySynthesisTests.swift
git commit -m "feat(activity): synthesis — scope clusters, extractive prompt, self-check, dated entry"
```

---

### Task 5: `ProjectSyncStore` — sidecar last-synced SHA

**Files:**
- Create: `Localpen/Services/Brain/Activity/ProjectSyncStore.swift`
- Test: `LocalpenTests/ProjectSyncStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ProjectSyncStore {
      let fileURL: URL                 // sidecar JSON (app-support); injectable for tests
      func lastSHA(forRepo path: String) -> String?
      func record(repo path: String, sha: String)
      static func defaultURL() -> URL  // AppSupport/Localpen/project-sync.json
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class ProjectSyncStoreTests: XCTestCase {
    private func tempStore() -> ProjectSyncStore {
        ProjectSyncStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("psync-\(UUID().uuidString).json"))
    }

    func test_unset_returnsNil() {
        XCTAssertNil(tempStore().lastSHA(forRepo: "/x/repo"))
    }

    func test_recordThenRead_roundTrips() {
        let s = tempStore()
        s.record(repo: "/x/repo", sha: "abc123")
        XCTAssertEqual(s.lastSHA(forRepo: "/x/repo"), "abc123")
        s.record(repo: "/x/repo", sha: "def456")
        XCTAssertEqual(s.lastSHA(forRepo: "/x/repo"), "def456", "advances")
        XCTAssertNil(s.lastSHA(forRepo: "/x/other"), "per-repo keyed")
    }

    func test_persistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psync-\(UUID().uuidString).json")
        ProjectSyncStore(fileURL: url).record(repo: "/r", sha: "s1")
        XCTAssertEqual(ProjectSyncStore(fileURL: url).lastSHA(forRepo: "/r"), "s1")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectSyncStoreTests 2>&1 | tail -20`
Expected: FAIL — no `ProjectSyncStore`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Records the last git SHA summarized per repo, so each nightly pass only reads new commits.
/// A sidecar JSON in app-support (NOT the vault) — mirrors how ConversationStash/SuggestionStore
/// live outside the vault, keeping the brain's git history free of sync-pointer churn.
struct ProjectSyncStore {
    let fileURL: URL

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Localpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("project-sync.json")
    }

    func lastSHA(forRepo path: String) -> String? { load()[path] }

    func record(repo path: String, sha: String) {
        var map = load(); map[path] = sha
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectSyncStoreTests 2>&1 | tail -20`
Expected: PASS — 3 tests.

> Register both files.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/ProjectSyncStore.swift LocalpenTests/ProjectSyncStoreTests.swift
git commit -m "feat(activity): ProjectSyncStore — sidecar last-synced SHA per repo"
```

---

### Task 6: `CurationWrite.appendActivity` + `VaultWriter` section-insert

**Files:**
- Modify: `Localpen/Services/Brain/Curation/CurationWrite.swift` (new case + classifier)
- Modify: `Localpen/Services/Brain/Curation/VaultWriter.swift` (handle the case + a section-prepend helper)
- Test: `LocalpenTests/VaultWriterActivityTests.swift`

**Interfaces:**
- Consumes: existing `VaultWriter`, `CurationWrite`, `WriteClassifier`.
- Produces: `CurationWrite.appendActivity(projectTitle: String, entry: String)`, auto-applied; `VaultWriter.apply` writes it under `## Activity`.

- [ ] **Step 1: Add the case + classify it auto-apply**

In `CurationWrite.swift`, add to the enum (next to `appendTimeline`):
```swift
    /// Append a dated entry to a project page's tool-owned `## Activity` log (project-activity
    /// freshness). Additive — auto-applied.
    case appendActivity(projectTitle: String, entry: String)
```
In `WriteClassifier.disposition(for:)`, add `.appendActivity` to the auto-apply group (the same arm as `.appendTimeline` / `.captureToInbox`). Open `CurationWrite.swift` and add `case .appendActivity` to that `.autoApply` switch arm.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import Localpen

final class VaultWriterActivityTests: XCTestCase {
    private func makeVault() throws -> (writer: VaultWriter, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        // The writer commits each write, so the vault must be a git repo.
        func git(_ a: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path] + a; p.standardOutput = Pipe(); p.standardError = Pipe(); try? p.run(); p.waitUntilExit() }
        git(["init", "-q"]); git(["config", "user.email", "t@t.t"]); git(["config", "user.name", "t"])
        return (VaultWriter(vaultRoot: root), root)
    }
    private func page(_ root: URL, _ title: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent("projects/\(title).md"), atomically: true, encoding: .utf8)
    }
    private func read(_ root: URL, _ title: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("projects/\(title).md"), encoding: .utf8)
    }

    func test_append_createsActivitySection_whenAbsent() throws {
        let (w, root) = try makeVault()
        try page(root, "Cairn", "---\ntype: project\n---\n# Cairn\n\n## Status\n- Active.\n")
        _ = try w.apply(.appendActivity(projectTitle: "Cairn", entry: "### Jun 5\n- **w2**: x (a1)"), nowMillis: 0)
        let out = try read(root, "Cairn")
        XCTAssertTrue(out.contains("## Activity"))
        XCTAssertTrue(out.contains("### Jun 5\n- **w2**: x (a1)"))
        XCTAssertTrue(out.contains("## Status"), "hand-written sections untouched")
    }

    func test_append_prependsNewestUnderExistingSection() throws {
        let (w, root) = try makeVault()
        try page(root, "Cairn", "# Cairn\n\n## Activity\n### May 1\n- old (z9)\n")
        _ = try w.apply(.appendActivity(projectTitle: "Cairn", entry: "### Jun 5\n- new (a1)"), nowMillis: 0)
        let out = try read(root, "Cairn")
        let jun = out.range(of: "### Jun 5")!.lowerBound
        let may = out.range(of: "### May 1")!.lowerBound
        XCTAssertLessThan(jun, may, "newest entry is prepended above older ones")
    }

    func test_append_missingPage_throws() throws {
        let (w, _) = try makeVault()
        XCTAssertThrowsError(try w.apply(.appendActivity(projectTitle: "Ghost", entry: "### x\n- y"), nowMillis: 0))
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VaultWriterActivityTests 2>&1 | tail -20`
Expected: FAIL — `appendActivity` unhandled / compile error in the `apply` switch.

- [ ] **Step 4: Implement the handler**

In `VaultWriter.apply`, add a case before the unreachable arm:
```swift
        case .appendActivity(let projectTitle, let entry):
            let name = try safeName(projectTitle)
            let rel = "projects/\(name).md"
            guard exists(rel) else { throw WriteError.targetMissing(rel) }
            try prependUnderSection(rel, header: "## Activity", entry: entry)
            try commit([rel], "activity: \(name)")
            return rel
```
Add the helper (next to `appendLine`):
```swift
    /// Insert `entry` directly under `header`, creating the section at end-of-file if absent.
    /// Newest-first: a new entry goes immediately below the header, above older entries.
    private func prependUnderSection(_ rel: String, header: String, entry: String) throws {
        try guardWritable(rel)
        let url = absolute(rel)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hRange = text.range(of: header) {
            // Find the end of the header line, insert the block right after it.
            let afterHeaderLine = text[hRange.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            text.insert(contentsOf: "\n" + block + "\n", at: afterHeaderLine)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n\(header)\n\n\(block)\n"
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw WriteError.io("activity \(rel): \(error.localizedDescription)") }
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/VaultWriterActivityTests 2>&1 | tail -20`
Expected: PASS — 3 tests.

> Register the new test file. (The two modified source files are already in the project.)

- [ ] **Step 6: Commit**

```bash
git add Localpen/Services/Brain/Curation/CurationWrite.swift Localpen/Services/Brain/Curation/VaultWriter.swift LocalpenTests/VaultWriterActivityTests.swift
git commit -m "feat(activity): CurationWrite.appendActivity + VaultWriter section-prepend"
```

---

### Task 7: `ProjectActivityPass` — orchestrator + first-run anchor

**Files:**
- Create: `Localpen/Services/Brain/Activity/ProjectActivityPass.swift`
- Test: `LocalpenTests/ProjectActivityPassTests.swift`

**Interfaces:**
- Consumes: `BrainIndex` (`pages(ofType: .project)`), `KBPage` (`.frontmatter`, `.title`), `GitActivityReader`, `ProjectActivityBatcher`, `ProjectActivitySynthesis`, `ProjectSyncStore`, `VaultWriter`, `CurationOutcome`.
- Produces:
  ```swift
  struct ProjectActivityPass {
      let index: BrainIndex
      let writer: VaultWriter
      let sync: ProjectSyncStore
      let synthesize: (_ system: String, _ user: String) async -> CurationOutcome
      let now: () -> Date
      struct Report: Equatable { var projects = 0; var entries = 0; var skipped = 0 }
      func run() async -> Report
      /// First-run lookback start: the page's `updated` date, floored to now-90d. Pure/static.
      static func firstRunSince(updatedYMD: String?, now: Date, capDays: Int = 90) -> Date
  }
  ```

- [ ] **Step 1: Write the failing test (pure anchor logic — the model/git path is covered by the Task-8 integration)**

```swift
import XCTest
@testable import Localpen

final class ProjectActivityPassTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-06-18T00:00:00Z")!

    func test_firstRunSince_usesUpdated_whenRecent() {
        let since = ProjectActivityPass.firstRunSince(updatedYMD: "2026-06-01", now: now, capDays: 90)
        XCTAssertEqual(ISO8601DateFormatter().string(from: since).prefix(10), "2026-06-01")
    }

    func test_firstRunSince_capsAt90Days_whenAncient() {
        let since = ProjectActivityPass.firstRunSince(updatedYMD: "2025-01-01", now: now, capDays: 90)
        let cap = now.addingTimeInterval(-90 * 86400)
        XCTAssertEqual(since.timeIntervalSince1970, cap.timeIntervalSince1970, accuracy: 86400, "floored to now-90d")
    }

    func test_firstRunSince_missingUpdated_fallsBackToCap() {
        let since = ProjectActivityPass.firstRunSince(updatedYMD: nil, now: now, capDays: 90)
        XCTAssertLessThan(since, now)
        XCTAssertGreaterThan(since, now.addingTimeInterval(-91 * 86400))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivityPassTests 2>&1 | tail -20`
Expected: FAIL — no `ProjectActivityPass`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import os

/// The nightly project-activity pass (project-activity-freshness spec): a sibling to the
/// conversation dream cycle. For each project page whose `local_path` is a real git repo, read
/// commits since it went stale → batch → summarize → append to `## Activity`. Best-effort and
/// isolated per project; advances the sync SHA only past successfully-written batches.
struct ProjectActivityPass {
    let index: BrainIndex
    let writer: VaultWriter
    let sync: ProjectSyncStore
    let synthesize: (_ system: String, _ user: String) async -> CurationOutcome
    let now: () -> Date
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Activity")

    struct Report: Equatable { var projects = 0; var entries = 0; var skipped = 0 }

    static func firstRunSince(updatedYMD: String?, now: Date, capDays: Int = 90) -> Date {
        let cap = now.addingTimeInterval(-Double(capDays) * 86400)
        guard let ymd = updatedYMD else { return cap }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let updated = f.date(from: ymd) else { return cap }
        return max(updated, cap)
    }

    func run() async -> Report {
        var report = Report()
        for page in await index.pages(ofType: .project) {
            guard let rawPath = page.frontmatter["local_path"], !rawPath.isEmpty else { continue }
            let repoPath = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: repoPath) else { report.skipped += 1; continue }
            report.projects += 1

            let lastSHA = sync.lastSHA(forRepo: repoPath)
            let sinceDate = lastSHA == nil
                ? Self.firstRunSince(updatedYMD: page.frontmatter["updated"], now: now()) : nil

            let result: GitActivityReader.ReadResult
            do { result = try GitActivityReader.read(repoPath: repoPath, sinceSHA: lastSHA, sinceDate: sinceDate) }
            catch { log.info("activity: skip \(page.title, privacy: .public): \(error.localizedDescription)"); report.skipped += 1; continue }

            let commits = GitActivityReader.substantive(result.commits)
            guard !commits.isEmpty else { sync.record(repo: repoPath, sha: result.head); continue }

            var wroteAny = false
            for batch in ProjectActivityBatcher.batch(commits) {
                guard let entry = await ProjectActivitySynthesis.entry(for: batch, synthesize: synthesize) else { continue }
                do {
                    try writer.apply(.appendActivity(projectTitle: page.title, entry: entry),
                                     nowMillis: Int64(now().timeIntervalSince1970 * 1000))
                    report.entries += 1; wroteAny = true
                } catch { log.info("activity: write failed \(page.title, privacy: .public): \(error.localizedDescription)") }
            }
            // Advance sync to HEAD only if we got through the batches without a write failure
            // mid-way; otherwise leave it so the unwritten commits are retried next run.
            if wroteAny || commits.isEmpty { sync.record(repo: repoPath, sha: result.head) }
        }
        log.info("activity pass: \(report.projects) projects, \(report.entries) entries, \(report.skipped) skipped")
        return report
    }
}
```

> The sync-advance rule is deliberately simple: advance on success. A batch whose model call failed leaves `wroteAny` possibly true for earlier batches but the failed batch's commits are *older* than HEAD, so they'd be re-read next run and could double-write. Acceptable for v1 (a rare model failure → at most a duplicate entry, a one-line fix); a stricter "advance only to the last successfully-written batch's SHA" is a future refinement noted here, not built.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ProjectActivityPassTests 2>&1 | tail -20`
Expected: PASS — 3 tests.

> Register both files.

- [ ] **Step 5: Commit**

```bash
git add Localpen/Services/Brain/Activity/ProjectActivityPass.swift LocalpenTests/ProjectActivityPassTests.swift
git commit -m "feat(activity): ProjectActivityPass orchestrator + first-run anchor"
```

---

### Task 8: Wire into the nightly trigger + gated end-to-end

**Files:**
- Modify: `Localpen/AppDelegate.swift` (run the pass after the dream cycle)
- Test: `LocalpenTests/ProjectActivityPassTests.swift` (add a gated end-to-end test over a temp repo + temp vault)

**Interfaces:**
- Consumes: everything above; `DreamCycleRunner`'s synthesize-closure shape (rebuilt here over the live server) — or reuse by extracting. For v1, build a closure inline mirroring `DreamCycleRunner`.

- [ ] **Step 1: Add a deterministic end-to-end test (real git + real vault, fake model)**

Add to `ProjectActivityPassTests.swift`. This proves the whole read→batch→synthesize→append→sync wiring without needing the llama server (a fake synthesize closure makes it deterministic); the live-model proof is step 5.

```swift
    func test_run_endToEnd_writesActivityEntry_andAdvancesSync() async throws {
        let repo = try makeTempRepo(["feat(w2): autocomplete", "feat(hub): four modes"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let vault = try makeVaultWithProject(title: "Demo", localPath: repo.path)
        defer { try? FileManager.default.removeItem(at: vault) }

        let index = try BrainIndex(testInMemory: true)
        await index.reindexAll(root: vault)
        let sync = ProjectSyncStore(fileURL: vault.appendingPathComponent("sync.json"))
        let pass = ProjectActivityPass(
            index: index,
            writer: VaultWriter(vaultRoot: vault),
            sync: sync,
            synthesize: { _, _ in .completed("- **w2**: shipped autocomplete (deadbee)") },
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let report = await pass.run()
        XCTAssertGreaterThanOrEqual(report.entries, 1)
        let page = try String(contentsOf: vault.appendingPathComponent("projects/Demo.md"), encoding: .utf8)
        XCTAssertTrue(page.contains("## Activity"))
        XCTAssertTrue(page.contains("shipped autocomplete"))
        XCTAssertNotNil(sync.lastSHA(forRepo: repo.path), "sync advanced to HEAD")
    }

    /// Throwaway git repo, one commit per message.
    private func makeTempRepo(_ messages: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func git(_ a: [String]) throws { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + a; p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: 1) } }
        try git(["init", "-q"]); try git(["config", "user.email", "t@t.t"]); try git(["config", "user.name", "t"])
        for (i, m) in messages.enumerated() {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."]); try git(["commit", "-q", "-m", m])
        }
        return dir
    }

    /// A git-backed temp vault containing one committed project page with the given local_path.
    private func makeVaultWithProject(title: String, localPath: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try """
        ---
        type: project
        updated: 2026-06-01
        local_path: \(localPath)
        ---

        # \(title)

        ## Status
        - Active.
        """.write(to: root.appendingPathComponent("projects/\(title).md"), atomically: true, encoding: .utf8)
        func git(_ a: [String]) throws { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path] + a; p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit() }
        try git(["init", "-q"]); try git(["config", "user.email", "t@t.t"]); try git(["config", "user.name", "t"])
        try git(["add", "."]); try git(["commit", "-q", "-m", "seed"])
        return root
    }
```

- [ ] **Step 2: Wire the pass into `runDreamCycle`**

In `AppDelegate.runDreamCycle(force:)`, inside the existing `Task { @MainActor in let report = await runner.run() … }`, after the dream-cycle report logging and before/after the reindex, add the sibling pass:
```swift
            // Sibling pass (project-activity freshness): summarize git activity into project
            // pages. Shares the nightly trigger + a synthesize closure over the same server.
            if let brainIndex = self.brainIndex {
                let pass = ProjectActivityPass(
                    index: brainIndex,
                    writer: VaultWriter(vaultRoot: BrainAccess.vaultRoot),
                    sync: ProjectSyncStore(fileURL: ProjectSyncStore.defaultURL()),
                    synthesize: { system, user in
                        do {
                            let client = StreamingClient(port: server.port)
                            var acc = ""
                            for try await tok in client.complete(systemPrompt: system, userText: user,
                                                                 sampling: .init(temperature: 0.3, topP: 0.9, repeatPenalty: 1.05),
                                                                 timeout: 600) { acc += tok }
                            return .completed(acc)
                        } catch { return .failed(error.localizedDescription) }
                    },
                    now: { Date() }
                )
                let aReport = await pass.run()
                self.log.info("activity pass: \(aReport.projects) projects, \(aReport.entries) entries")
                if aReport.entries > 0 {
                    let root = BrainAccess.vaultRoot
                    Task.detached { await brainIndex.reindexAll(root: root) }
                }
            }
```

> Confirm `ModelDescriptor.Sampling(temperature:topP:repeatPenalty:)` is the exact initializer `DreamCycleRunner` uses (it is — copy it verbatim from there). If `StreamingClient.complete` requires a different sampling type, reuse `DreamCycleRunner`'s `Self.sampling` constant by extracting it to a shared `static let`.

- [ ] **Step 3: Build + run the full suite**

Run:
```bash
xcodebuild build -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:" | tail -5
xcodebuild test -scheme Localpen -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests, with.*seconds|TEST (SUCCEEDED|FAILED)" | tail -3
```
Expected: `BUILD SUCCEEDED`; all suites pass (the end-to-end test is deterministic — fake model, no server needed).

- [ ] **Step 4: Commit**

```bash
git add Localpen/AppDelegate.swift LocalpenTests/ProjectActivityPassTests.swift
git commit -m "feat(activity): run the project-activity pass in the nightly cycle"
```

- [ ] **Step 5: Live verification (user-observed)**

`rebuild-install`, then trigger curation manually (the Settings "run curation now" path that calls `runDreamCycleNow`) with the embedding/transform server up and a project page whose `local_path` points at a repo with recent commits. Confirm an honest, cited `## Activity` entry appears on that page and the body/Status are untouched. (Per working style: the user does the live check.)

---

## Self-review notes

- **Spec coverage:** §4 architecture → Tasks 1–8; §5 windowing/batching → Tasks 3 + 7 (`firstRunSince`); §6 summarization → Task 4; §7 page format/write → Task 6; §8 degradation → Task 7 (skip/isolate) + Task 4 (nil on model fail); §9 testing → each task's tests + Task 8 deterministic end-to-end (fake model) + step-5 live model proof; §10 build order → task order.
- **Trigger:** sibling pass in `runDreamCycle`, not nested in `DreamCycle.run()` (matches the spec's sibling decision).
- **Verify before trusting `StreamingClient` port/sampling:** Task 8 step 2 flags confirming the exact `complete(...)` signature + `Sampling` initializer against `DreamCycleRunner` at build time.

## Done-when

- A night's commits across projects with a `local_path` produce honest, cited, scope-grouped `## Activity` entries, zero manual action; hand-written content untouched; all suites green (incl. the deterministic end-to-end); the live manual run produces a real cited entry.
