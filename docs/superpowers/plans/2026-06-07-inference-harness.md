# Inference Measurement Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Granularity note (deliberate):** Per the repo owner's standing preference (memory `feedback_build_proper_version_not_granular_phases`), tasks here are coarser than the writing-plans default — each task is a complete, compilable unit, not a 2-minute micro-step. TDD is applied where there is a *pure function* worth pinning (the timings parser, the JSONL row encoder); shell/wiring is verified by running it, not by ceremony.

**Goal:** Build the measurement substrate for Localpen's local inference — capture per-request `timings` (TTFT, tok/s, and speculative-decoding acceptance when present) from the two real workloads (rewrite + ask-notes), and provide an offline `llama-bench` wrapper for controlled config comparison. This is the rigor layer that `inference-quickwins` will measure its wins against.

**Architecture:** Two independent pieces. (1) **In-app telemetry** — `StreamingClient` already streams `/v1/chat/completions`; we add `"timings_per_token": true` to the request, parse the llama-server `timings` object out of the SSE chunks, and forward it through an opt-in `onTimings` callback to a singleton `InferenceMetrics` sink that logs to `os.Logger` and appends a JSONL row tagged by workload. (2) **Offline bench** — a `scripts/bench/run-bench.sh` wrapper around the vendored `llama-bench` that runs the active GGUF with the app's real server flags and writes a timestamped, build-stamped result table.

**Tech Stack:** Swift (XCTest, `os.Logger`, `Codable`, `URLSession.bytes`), llama.cpp `llama-server` (build 9544) `/v1/chat/completions`, `llama-bench`, bash.

---

## Ground truth (verified live 2026-06-07 against build 9544)

**Non-streaming and streaming-with-`timings_per_token:true` both return a top-level `timings` object. Exact shape:**

```json
"timings": {
  "cache_n": 0,
  "prompt_n": 36,
  "prompt_ms": 308.033,
  "prompt_per_token_ms": 8.556,
  "prompt_per_second": 116.87,
  "predicted_n": 4,
  "predicted_ms": 110.123,
  "predicted_per_token_ms": 27.53,
  "predicted_per_second": 36.32
}
```

- **TTFT proxy** = `prompt_ms` (prompt-eval wall time before first decoded token).
- **Decode throughput** = `predicted_per_second` (tok/s).
- **Speculative-decoding acceptance**: when a draft model is loaded (the `inference-quickwins` branch), llama-server adds `draft_n` and `draft_n_accepted` to this same object. They are **absent today** (no draft model). The struct must decode them as optional and compute `accepted/total` only when present.
- Streaming: with `"timings_per_token": true`, each SSE `data:` chunk carries a `timings` object; the **last** chunk's object is the complete one. Parse every chunk, keep the latest, emit once at stream end.

**`llama-bench` wrinkle:** the vendored `/Users/charliexue/School/clones/llama.cpp/build/bin/llama-bench` is a *stale binary* — it prints `build: a133566d3 (4500)` but dynamically loads the rebuilt 9544 dylibs from the same dir, so its t/s numbers reflect 9544 kernels. Do **not** trust llama-bench's `build:` line; stamp the result with `llama-server --version` instead. (See memory `project_llama_server_binary_deps`.)

---

## File Structure

**New files:**
- `Localpen/Services/ServerTimings.swift` — `Codable` struct mirroring the `timings` object + a parser that pulls it out of one SSE chunk. One responsibility: model + parse server timings. ~50 lines.
- `Localpen/Services/InferenceMetrics.swift` — the sink. `Workload` enum, singleton `shared`, pure `encodeRow(...)`, side-effecting `record(...)` (os.Logger + JSONL append). ~70 lines.
- `LocalpenTests/ServerTimingsTests.swift` — parser unit tests.
- `LocalpenTests/InferenceMetricsTests.swift` — row-encoder unit tests.
- `scripts/bench/run-bench.sh` — offline llama-bench wrapper.
- `scripts/bench/README.md` — how to run the offline bench + how to read the in-app JSONL.

**Modified files:**
- `Localpen/Services/StreamingClient.swift` — add `timings_per_token` to `requestBody`; add `onTimings` param to `complete(...)`; parse timings in the SSE loop.
- `Localpen/Panel/PanelController.swift` — rewrite path (`runStream`) passes `onTimings` tagging `.rewrite`; the default `askStreamProvider` (in `init`) passes `onTimings` tagging `.ask`.

**Interface contract (names used across tasks — keep consistent):**
- `struct ServerTimings: Codable, Equatable` with stored props: `promptN: Int`, `promptMs: Double`, `predictedN: Int`, `predictedMs: Double`, `predictedPerSecond: Double`, `draftN: Int?`, `draftNAccepted: Int?`; computed `acceptanceRate: Double?`.
- `static func ServerTimings.parse(sseChunkJSON: [String: Any]) -> ServerTimings?`
- `enum Workload: String { case rewrite, ask }`
- `InferenceMetrics.shared.record(_ workload: Workload, _ timings: ServerTimings)`
- `static func InferenceMetrics.encodeRow(workload: Workload, timings: ServerTimings, atMillis: Int64) -> String`
- `StreamingClient.complete(systemPrompt:userText:sampling:timeout:onTimings:)` — `onTimings: (@Sendable (ServerTimings) -> Void)? = nil`

---

## Task 1: `ServerTimings` — model + parser (TDD)

**Files:**
- Create: `Localpen/Services/ServerTimings.swift`
- Test: `LocalpenTests/ServerTimingsTests.swift`

CodingKeys map snake_case JSON → camelCase Swift. The parser takes an already-deserialized chunk dict (the SSE loop in StreamingClient already does `JSONSerialization.jsonObject`), pulls the `timings` sub-dict, and decodes it. Decoding from `[String:Any]` is done by re-serializing the sub-dict and running `JSONDecoder` — small and avoids hand-rolling.

- [ ] **Step 1 — Write the failing tests.**

```swift
// LocalpenTests/ServerTimingsTests.swift
import XCTest
@testable import Localpen

final class ServerTimingsTests: XCTestCase {
    private func chunk(_ timingsJSON: String) -> [String: Any] {
        let s = "{\"choices\":[],\"timings\":\(timingsJSON)}"
        return try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
    }

    func test_parse_realTimings_noDraft() {
        let t = ServerTimings.parse(sseChunkJSON: chunk(
            #"{"prompt_n":36,"prompt_ms":308.033,"predicted_n":4,"predicted_ms":110.123,"predicted_per_second":36.32}"#))
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.promptN, 36)
        XCTAssertEqual(t?.promptMs ?? 0, 308.033, accuracy: 0.001)
        XCTAssertEqual(t?.predictedPerSecond ?? 0, 36.32, accuracy: 0.001)
        XCTAssertNil(t?.draftN)
        XCTAssertNil(t?.acceptanceRate)   // no draft fields → nil, not 0
    }

    func test_parse_withDraftFields_computesAcceptance() {
        let t = ServerTimings.parse(sseChunkJSON: chunk(
            #"{"prompt_n":10,"prompt_ms":50,"predicted_n":20,"predicted_ms":100,"predicted_per_second":200,"draft_n":16,"draft_n_accepted":12}"#))
        XCTAssertEqual(t?.draftN, 16)
        XCTAssertEqual(t?.draftNAccepted, 12)
        XCTAssertEqual(t?.acceptanceRate ?? 0, 0.75, accuracy: 0.0001)
    }

    func test_parse_chunkWithoutTimings_returnsNil() {
        let dict = try! JSONSerialization.jsonObject(
            with: #"{"choices":[{"delta":{"content":"hi"}}]}"#.data(using: .utf8)!) as! [String: Any]
        XCTAssertNil(ServerTimings.parse(sseChunkJSON: dict))
    }

    func test_acceptanceRate_zeroDraftN_isNil() {
        let t = ServerTimings.parse(sseChunkJSON: chunk(
            #"{"prompt_n":1,"prompt_ms":1,"predicted_n":1,"predicted_ms":1,"predicted_per_second":1,"draft_n":0,"draft_n_accepted":0}"#))
        XCTAssertNil(t?.acceptanceRate)   // guard against divide-by-zero
    }
}
```

- [ ] **Step 2 — Run, verify it fails to compile (`ServerTimings` undefined).**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ServerTimingsTests 2>&1 | tail -20`
Expected: build failure, "cannot find 'ServerTimings' in scope".

- [ ] **Step 3 — Implement.**

```swift
// Localpen/Services/ServerTimings.swift
import Foundation

/// One llama-server `timings` object, as returned on every `/v1/chat/completions`
/// response (and on each streaming chunk when `timings_per_token: true`). Field
/// names verified against llama.cpp build 9544. `draftN`/`draftNAccepted` appear
/// only when a draft model is loaded (speculative decoding — the
/// `inference-quickwins` branch); they are nil otherwise.
struct ServerTimings: Codable, Equatable {
    let promptN: Int
    let promptMs: Double
    let predictedN: Int
    let predictedMs: Double
    let predictedPerSecond: Double
    let draftN: Int?
    let draftNAccepted: Int?

    enum CodingKeys: String, CodingKey {
        case promptN = "prompt_n"
        case promptMs = "prompt_ms"
        case predictedN = "predicted_n"
        case predictedMs = "predicted_ms"
        case predictedPerSecond = "predicted_per_second"
        case draftN = "draft_n"
        case draftNAccepted = "draft_n_accepted"
    }

    /// Accepted draft tokens / proposed draft tokens. Nil when no draft model is
    /// active (or zero proposals) so callers can distinguish "spec off" from "0%".
    var acceptanceRate: Double? {
        guard let total = draftN, total > 0, let ok = draftNAccepted else { return nil }
        return Double(ok) / Double(total)
    }

    /// Pull `timings` out of an already-deserialized SSE chunk dict. Returns nil if
    /// the chunk carries no timings (content-only chunks, or `[DONE]`).
    static func parse(sseChunkJSON: [String: Any]) -> ServerTimings? {
        guard let timings = sseChunkJSON["timings"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: timings) else { return nil }
        return try? JSONDecoder().decode(ServerTimings.self, from: data)
    }
}
```

- [ ] **Step 4 — Run tests, verify green.**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/ServerTimingsTests 2>&1 | tail -20`
Expected: 4 tests pass.

- [ ] **Step 5 — Commit.**

```bash
git add Localpen/Services/ServerTimings.swift LocalpenTests/ServerTimingsTests.swift
git commit -m "feat(harness): ServerTimings model + SSE-chunk parser"
```

---

## Task 2: `InferenceMetrics` sink — row encoder (TDD) + logging/JSONL side effect

**Files:**
- Create: `Localpen/Services/InferenceMetrics.swift`
- Test: `LocalpenTests/InferenceMetricsTests.swift`

The pure, tested core is `encodeRow` (deterministic JSONL line). The `record` method is the thin side-effecting wrapper (os.Logger + file append) and is not unit-tested — it's verified live in Task 5. Timestamp is **epoch milliseconds** (`Int64`) to match the app's ms-timestamp invariant (memory `project_memory_subproject_a_shipped`). JSONL row keys are sorted for stable diffs, mirroring `VoiceDataExporter`.

- [ ] **Step 1 — Write the failing tests.**

```swift
// LocalpenTests/InferenceMetricsTests.swift
import XCTest
@testable import Localpen

final class InferenceMetricsTests: XCTestCase {
    func test_encodeRow_shapeAndFields() throws {
        let t = ServerTimings.parse(sseChunkJSON:
            try! JSONSerialization.jsonObject(with:
                #"{"timings":{"prompt_n":36,"prompt_ms":308.0,"predicted_n":40,"predicted_ms":1100.0,"predicted_per_second":36.4}}"#
                .data(using: .utf8)!) as! [String: Any])!
        let line = InferenceMetrics.encodeRow(workload: .rewrite, timings: t, atMillis: 1_700_000_000_000)
        // One line, valid JSON, no trailing newline.
        XCTAssertFalse(line.contains("\n"))
        let obj = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["workload"] as? String, "rewrite")
        XCTAssertEqual(obj["ts_ms"] as? Int64 ?? Int64(obj["ts_ms"] as? Int ?? 0), 1_700_000_000_000)
        XCTAssertEqual(obj["prompt_ms"] as? Double, 308.0)         // TTFT proxy
        XCTAssertEqual(obj["tok_per_s"] as? Double, 36.4)          // decode throughput
        XCTAssertNil(obj["acceptance_rate"])                       // absent when spec off
    }

    func test_encodeRow_includesAcceptanceWhenPresent() throws {
        let t = ServerTimings.parse(sseChunkJSON:
            try! JSONSerialization.jsonObject(with:
                #"{"timings":{"prompt_n":1,"prompt_ms":1,"predicted_n":20,"predicted_ms":100,"predicted_per_second":200,"draft_n":16,"draft_n_accepted":12}}"#
                .data(using: .utf8)!) as! [String: Any])!
        let line = InferenceMetrics.encodeRow(workload: .ask, timings: t, atMillis: 1)
        let obj = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["workload"] as? String, "ask")
        XCTAssertEqual(obj["acceptance_rate"] as? Double ?? 0, 0.75, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2 — Run, verify fail (`InferenceMetrics` undefined).**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/InferenceMetricsTests 2>&1 | tail -20`
Expected: build failure, "cannot find 'InferenceMetrics'".

- [ ] **Step 3 — Implement.**

```swift
// Localpen/Services/InferenceMetrics.swift
import Foundation
import os

/// Which real workload produced a measurement. Keep the raw values stable —
/// they are the `workload` column in the JSONL and any later analysis groups on them.
enum Workload: String {
    case rewrite   // transform / quick-actions (Proofread, Polish, …)
    case ask       // free-form ask over the brain
}

/// Per-request inference telemetry sink. Best-effort and non-fatal: a failed file
/// write must never disturb a user-facing generation. Two outputs:
///   1. os.Logger (category "Metrics") — live tailing via Console.app / `log stream`.
///   2. ~/Library/Logs/Localpen/inference-metrics.jsonl — durable, one JSON row per request.
final class InferenceMetrics: @unchecked Sendable {
    static let shared = InferenceMetrics()

    private let log = Logger(subsystem: "app.localpen.Localpen", category: "Metrics")
    private let queue = DispatchQueue(label: "app.localpen.metrics")   // serialize appends
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Localpen", isDirectory: true)
        self.fileURL = fileURL ?? logDir.appendingPathComponent("inference-metrics.jsonl")
    }

    /// Deterministic single-line JSON row. Pure — unit-tested. `acceptance_rate`
    /// is omitted entirely when no draft model is active.
    static func encodeRow(workload: Workload, timings t: ServerTimings, atMillis: Int64) -> String {
        var obj: [String: Any] = [
            "ts_ms": atMillis,
            "workload": workload.rawValue,
            "prompt_n": t.promptN,
            "prompt_ms": t.promptMs,
            "predicted_n": t.predictedN,
            "predicted_ms": t.predictedMs,
            "tok_per_s": t.predictedPerSecond,
        ]
        if let rate = t.acceptanceRate { obj["acceptance_rate"] = rate }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Record one request's timings. Safe to call from any thread / actor.
    func record(_ workload: Workload, _ timings: ServerTimings) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let row = Self.encodeRow(workload: workload, timings: timings, atMillis: ms)
        if let rate = timings.acceptanceRate {
            log.info("\(workload.rawValue, privacy: .public): \(timings.predictedPerSecond, format: .fixed(precision: 1)) tok/s, TTFT \(timings.promptMs, format: .fixed(precision: 0))ms, accept \(rate, format: .fixed(precision: 2))")
        } else {
            log.info("\(workload.rawValue, privacy: .public): \(timings.predictedPerSecond, format: .fixed(precision: 1)) tok/s, TTFT \(timings.promptMs, format: .fixed(precision: 0))ms")
        }
        queue.async { [fileURL, row] in
            guard let line = (row + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)   // first write creates the file
            }
        }
    }
}
```

- [ ] **Step 4 — Run tests, verify green.**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/InferenceMetricsTests 2>&1 | tail -20`
Expected: 2 tests pass.

- [ ] **Step 5 — Commit.**

```bash
git add Localpen/Services/InferenceMetrics.swift LocalpenTests/InferenceMetricsTests.swift
git commit -m "feat(harness): InferenceMetrics sink (os.Logger + JSONL row)"
```

---

## Task 3: Wire timings through `StreamingClient`

**Files:**
- Modify: `Localpen/Services/StreamingClient.swift`
- Test: `LocalpenTests/StreamingBodyTests.swift` (extend)

Two changes: (a) request `timings_per_token: true` so streaming chunks carry timings; (b) add an optional `onTimings` callback fired once at stream end with the last-seen timings. Keep the yielded element type `String` (content) unchanged so no caller breaks.

> **Read first:** open `Localpen/Services/StreamingClient.swift` end-to-end (it's ~81 lines). Confirm the exact signature of `complete(...)` and the SSE loop variable names before editing — the snippet below assumes `requestBody(messages:sampling:)` and a `for try await line in bytes.lines` loop yielding into a `continuation`.

- [ ] **Step 1 — Add a test asserting `timings_per_token` is in the body.**

```swift
// append to LocalpenTests/StreamingBodyTests.swift
func test_body_requestsPerTokenTimings() {
    let body = StreamingClient.requestBody(
        messages: [("user", "hi")], sampling: nil)
    XCTAssertEqual(body["timings_per_token"] as? Bool, true)
}
```

- [ ] **Step 2 — Run, verify fail.**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/StreamingBodyTests 2>&1 | tail -15`
Expected: `test_body_requestsPerTokenTimings` fails (key missing / nil).

- [ ] **Step 3 — Add the flag to `requestBody`.**

In `StreamingClient.requestBody(...)`, add one key to the returned dict:

```swift
        "repeat_penalty": sampling?.repeatPenalty ?? 1.05,
        "timings_per_token": true        // surface llama-server timings on each SSE chunk
```

- [ ] **Step 4 — Add `onTimings` to `complete(...)` and parse in the loop.**

Update the signature (add the last param) — keep all existing params/defaults:

```swift
    func complete(systemPrompt: String,
                  userText: String,
                  sampling: ModelDescriptor.Sampling? = nil,
                  timeout: TimeInterval = 60,
                  onTimings: (@Sendable (ServerTimings) -> Void)? = nil) -> AsyncThrowingStream<String, Error> {
```

Inside the producing Task, declare a latest-timings holder before the SSE loop, capture timings per chunk, and fire once after the loop:

```swift
            var latestTimings: ServerTimings?
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let t = ServerTimings.parse(sseChunkJSON: json) { latestTimings = t }
                if let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    continuation.yield(content)
                }
            }
            if let t = latestTimings { onTimings?(t) }
            continuation.finish()
```

(Adapt to the file's exact existing structure — the key additions are `latestTimings`, the `ServerTimings.parse` line, and the `onTimings?(t)` call before finishing. A cancelled or thrown stream simply skips the callback, which is correct — we only record completed generations.)

- [ ] **Step 5 — Build + run the streaming tests, verify green.**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' -only-testing:LocalpenTests/StreamingBodyTests 2>&1 | tail -15`
Expected: all StreamingBodyTests pass (including the new one).

- [ ] **Step 6 — Commit.**

```bash
git add Localpen/Services/StreamingClient.swift LocalpenTests/StreamingBodyTests.swift
git commit -m "feat(harness): StreamingClient surfaces server timings via onTimings"
```

---

## Task 4: Tag the two workloads in `PanelController`

**Files:**
- Modify: `Localpen/Panel/PanelController.swift` (rewrite call site `runStream` ~line 1010; default `askStreamProvider` in `init` ~line 307)

Both call sites already exist. We only add `onTimings:` closures that forward to `InferenceMetrics.shared.record(...)` with the correct `Workload`. No behavior change to generation.

> **Read first:** open `PanelController.swift` around lines 990–1031 (`runStream`) and 287–310 (`init` / default `askStreamProvider`). Confirm the exact call to `streaming.complete(...)` in `runStream` and the default-closure body before editing.

- [ ] **Step 1 — Rewrite path.** In `runStream(action:selection:)`, add the callback to the existing `streaming.complete(...)` call:

```swift
        for try await token in streaming.complete(
            systemPrompt: systemPrompt, userText: userPrompt, sampling: sampling,
            onTimings: { InferenceMetrics.shared.record(.rewrite, $0) }) {
```

(Keep the existing `timeout:` argument if present on this call — just add `onTimings:` alongside it.)

- [ ] **Step 2 — Ask path.** In `init`, the default `askStreamProvider` forwards to `streaming.complete`. Add the callback there so production asks are tagged; test-injected providers stay untagged:

```swift
        self.askStreamProvider = askStreamProvider ?? { [streaming] sys, user, sampling in
            streaming.complete(systemPrompt: sys, userText: user, sampling: sampling,
                               onTimings: { InferenceMetrics.shared.record(.ask, $0) })
        }
```

- [ ] **Step 3 — Build, verify clean.**

Run: `xcodebuild build -scheme Localpen -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED` (the pre-existing `FilesContextSource` Sendable warning is fine).

- [ ] **Step 4 — Commit.**

```bash
git add Localpen/Panel/PanelController.swift
git commit -m "feat(harness): tag rewrite + ask requests with workload metrics"
```

---

## Task 5: Offline `llama-bench` wrapper + README

**Files:**
- Create: `scripts/bench/run-bench.sh` (executable)
- Create: `scripts/bench/README.md`

Mirror the conventions of the existing `scripts/*.sh` (`set -euo pipefail`, `cd` to repo root, echo-with-`▸` progress). The wrapper runs `llama-bench` against the **active** chat GGUF with the app's real server flags (flash-attn on), and stamps the result with the *server's* real build (not llama-bench's stale string). Override points via env vars so `inference-quickwins` can sweep configs.

- [ ] **Step 1 — Write the script.**

```bash
#!/usr/bin/env bash
# Offline inference microbenchmark for Localpen's active chat model.
# Wraps llama.cpp's llama-bench with the flags the app actually runs, and stamps
# the result with the *server's* real build (llama-bench's own --version is stale;
# see docs/superpowers/plans/2026-06-07-inference-harness.md). Use this to compare
# config changes (the inference-quickwins branch) on a controlled, repeatable bench.
set -euo pipefail
cd "$(dirname "$0")/../.."

LLAMA_DIR="${LLAMA_DIR:-/Users/charliexue/School/clones/llama.cpp/build/bin}"
BENCH="${LLAMA_BENCH:-$LLAMA_DIR/llama-bench}"
SERVER="${LLAMA_SERVER:-Localpen/Resources/llama-server}"
MODEL="${MODEL:-$HOME/Library/Application Support/Localpen/models/qwen-2.5-7b-instruct-q4-km.gguf}"
# Two real-workload-ish shapes: rewrite (short prompt, short gen) and ask (long prompt, longer gen).
PROMPTS="${PROMPTS:-128,1024}"
GENS="${GENS:-64,256}"
REPS="${REPS:-3}"
FA="${FA:-1}"
NGL="${NGL:-999}"

[ -x "$BENCH" ] || { echo "✗ llama-bench not found/executable at $BENCH (set LLAMA_BENCH=)"; exit 1; }
[ -f "$MODEL" ] || { echo "✗ model not found at $MODEL (set MODEL=)"; exit 1; }

BUILD="$("$SERVER" --version 2>&1 | awk '/^version:/{print $2}' || echo unknown)"
OUTDIR="docs/superpowers/bench-results"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUTDIR/bench-$STAMP.txt"

echo "▸ llama-bench — server build $BUILD — pp=$PROMPTS tg=$GENS reps=$REPS fa=$FA"
{
  echo "# Localpen offline bench"
  echo "# date:        $STAMP"
  echo "# server build: $BUILD   (llama-bench binary build string is stale — ignore it)"
  echo "# model:       $(basename "$MODEL")"
  echo "# flags:       -p $PROMPTS -n $GENS -r $REPS -fa $FA -ngl $NGL"
  echo
  "$BENCH" -m "$MODEL" -p "$PROMPTS" -n "$GENS" -r "$REPS" -fa "$FA" -ngl "$NGL"
} | tee "$OUT"

echo "✓ wrote $OUT"
```

- [ ] **Step 2 — Make it executable + write the README.**

```bash
chmod +x scripts/bench/run-bench.sh
```

```markdown
<!-- scripts/bench/README.md -->
# Inference bench

Two ways to measure Localpen's local inference.

## 1. Offline microbench (controlled, repeatable)

`./scripts/bench/run-bench.sh`

Runs `llama-bench` against the active chat GGUF with the app's real server flags
and writes a build-stamped table to `docs/superpowers/bench-results/bench-<ts>.txt`.
`pp<N>` rows = prompt-eval throughput (TTFT driver); `tg<N>` rows = decode tok/s.

Override anything via env: `MODEL=`, `PROMPTS=128,1024`, `GENS=64,256`, `REPS=5`,
`FA=1`, `LLAMA_BENCH=`. Use this to A/B a config change (e.g. KV q8_0) on the
`inference-quickwins` branch — run before, run after, diff the tables.

> Note: the vendored `llama-bench` prints a stale `build:` line (4500) but loads the
> rebuilt 9544 dylibs, so its numbers are valid. The script stamps the real server
> build itself. To make llama-bench's own string match, rebuild it:
> `cmake --build /Users/charliexue/School/clones/llama.cpp/build --target llama-bench`.

## 2. In-app real-workload telemetry (live)

Every real generation appends one JSON row to
`~/Library/Logs/Localpen/inference-metrics.jsonl`, tagged `rewrite` or `ask`:

```
tail -f ~/Library/Logs/Localpen/inference-metrics.jsonl
```

Each row: `ts_ms`, `workload`, `prompt_ms` (TTFT proxy), `tok_per_s`,
`predicted_n`, and `acceptance_rate` (only when a draft model is active —
speculative decoding, the `inference-quickwins` branch). Live tailing without the
file: `log stream --predicate 'subsystem == "app.localpen.Localpen" && category == "Metrics"'`.
```

- [ ] **Step 3 — Run the bench (smoke), verify it writes a stamped table.**

Run: `REPS=1 PROMPTS=128 GENS=64 ./scripts/bench/run-bench.sh 2>&1 | tail -12`
Expected: a markdown-ish table with `pp128` and `tg64` rows and nonzero t/s, plus `✓ wrote docs/superpowers/bench-results/bench-<ts>.txt`. The header line shows `server build: 9544`.

- [ ] **Step 4 — Commit (script + README only; do not commit the throwaway smoke result).**

```bash
echo "docs/superpowers/bench-results/" >> .gitignore
git add scripts/bench/run-bench.sh scripts/bench/README.md .gitignore
git commit -m "feat(harness): offline llama-bench wrapper + bench README"
```

---

## Task 6: Live end-to-end verification

No new code — prove the in-app telemetry actually writes rows for both workloads. This honors the repo norm "verify yourself, quote output" (memory `feedback_verify_yourself`) and "no scripted-hotkey GUI testing" (memory `feedback_no_scripted_hotkey_testing`) — so the human triggers one rewrite + one ask; the agent only inspects the resulting file.

- [ ] **Step 1 — Rebuild + install + relaunch.**

Run: `./scripts/rebuild-install.sh`
Expected: `✓ installed … fresh build is running`.

- [ ] **Step 2 — Reset the metrics file so new rows are unambiguous.**

Run: `: > ~/Library/Logs/Localpen/inference-metrics.jsonl`

- [ ] **Step 3 — Ask the human to do exactly two things in the live app:** (1) select text and run a transform action (e.g. Proofread); (2) open the ask surface and ask one question. *(Agent: do not script the hotkey — hand this to the user.)*

- [ ] **Step 4 — Verify both workloads recorded.**

Run: `cat ~/Library/Logs/Localpen/inference-metrics.jsonl`
Expected: ≥2 rows; at least one `"workload":"rewrite"` and one `"workload":"ask"`; each with nonzero `tok_per_s` and `prompt_ms`; no `acceptance_rate` key (spec decoding off — correct).

- [ ] **Step 5 — Final full test pass.**

Run: `xcodebuild test -scheme Localpen -destination 'platform=macOS' 2>&1 | tail -15`
Expected: whole suite green.

---

## Acceptance criteria (from the parallel-build-map "done" for inference-harness)

> *"emits tok/s, TTFT, and (when spec on) acceptance for the two real workloads (rewrite vs ask-notes); documented run command."*

- ✅ **tok/s** — `predicted_per_second` → JSONL `tok_per_s`; offline `tg<N>` rows.
- ✅ **TTFT** — `prompt_ms` → JSONL `prompt_ms`; offline `pp<N>` rows. (Complements the existing client-side `hotkey→first-token` log in `PanelController`.)
- ✅ **acceptance (when spec on)** — `acceptanceRate` emitted only when `draft_n` present; absent today by design, lights up automatically once `inference-quickwins` loads a draft model.
- ✅ **two real workloads** — `.rewrite` and `.ask` tagged at their real call sites.
- ✅ **documented run command** — `scripts/bench/README.md` (offline) + the `tail`/`log stream` commands (live).

## Out of scope (YAGNI — do not build here)

- No aggregation/dashboard/percentiles over the JSONL — it's an append log; analyze ad hoc.
- No changes to sampling/KV/flags/draft model — that's `inference-quickwins`. The harness only *measures*.
- No client-side wall-clock TTFT plumbing into the JSONL — server `prompt_ms` is the controllable signal and the existing latency log already covers wall-clock.

## Self-review checklist (done while writing)

- **Spec coverage:** every build-map acceptance bullet maps to a task (table above). ✅
- **Placeholder scan:** no TBD/"handle errors"/"similar to" — all code is concrete. ✅
- **Type consistency:** `ServerTimings` field/key names, `Workload` raw values, `encodeRow`/`record`/`parse` signatures, and the `complete(...onTimings:)` signature are identical everywhere they appear across Tasks 1–4. ✅
- **Build-map dependency note:** the old `feat/llama-server-seams` prep branch is moot (hybrid-rag already rewrote `LlamaServerController`); branch this off **current `main`**. ✅
```
