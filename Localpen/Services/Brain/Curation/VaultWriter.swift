import Foundation
import os

/// Applies ADDITIVE curation writes (ADR 0015) to the Obsidian vault, one atomic git
/// commit per write. Git is the backstop: every write is a discrete, revertable commit.
///
/// Honors `cxkb/CLAUDE.md`:
/// - **Stages only the explicit path it touched — never `git add -A`** (the "Lesson
///   learned 2026-05-27" rule; the older ingest section still says `-A`, but the explicit
///   prohibition is the more recent, more specific decision). An automated writer must
///   never sweep in unrelated files.
/// - `raw/` is immutable except the `raw/inbox/` capture target.
///
/// Defense in depth: refuses any write the classifier calls high-judgment (those are
/// queued as suggestions, never written unsupervised), refuses path-escaping names, and
/// refuses to overwrite an existing curated source page.
///
/// File/git IO only — a plain struct, testable against a throwaway git repo.
struct VaultWriter {
    enum WriteError: Error, Equatable {
        case notAdditive               // a high-judgment write reached the writer
        case unsafeName(String)        // a model-supplied name tried to escape the vault
        case targetMissing(String)     // append/nominate target page doesn't exist
        case targetExists(String)      // createSource would overwrite a curated page
        case immutable(String)         // a write under raw/ outside raw/inbox/
        case io(String)
        case git(String)
    }

    let vaultRoot: URL
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "VaultWriter")

    /// Apply one additive write. Returns the vault-relative path committed (for logging /
    /// dedupe). Throws `notAdditive` for anything the classifier queues.
    @discardableResult
    func apply(_ write: CurationWrite, nowMillis: Int64) throws -> String {
        guard WriteClassifier.disposition(for: write) == .autoApply else {
            throw WriteError.notAdditive
        }

        switch write {
        case .captureToInbox(let text):
            let rel = "raw/inbox/\(nowMillis).md"
            try writeFile(rel, contents: text)
            try commit([rel], "capture: inbox \(nowMillis)")
            return rel

        case .createSource(let title, let body):
            let name = try safeName(title)
            let rel = "sources/\(name).md"
            guard !exists(rel) else { throw WriteError.targetExists(rel) }
            try writeFile(rel, contents: body)
            try commit([rel], "source: \(name)")
            return rel

        case .appendTimeline(let person, let entry):
            let name = try safeName(person)
            let rel = "people/\(name).md"
            // A NEW person is high-judgment (queued) — the writer only appends to one
            // that already exists.
            guard exists(rel) else { throw WriteError.targetMissing(rel) }
            try appendLine(rel, "- \(entry)")
            try commit([rel], "people: timeline \(name)")
            return rel

        case .nominateLink(let fromPage, let toTitle):
            let fromName = try safeName(fromPage)
            let toName = try safeName(toTitle)
            guard let rel = resolvePage(titled: fromName) else {
                throw WriteError.targetMissing("\(fromName).md")
            }
            try appendLine(rel, "- [[\(toName)]]")
            try commit([rel], "link: \(fromName) -> \(toName)")
            return rel

        case .updateNow(let text):
            // now.md is volatile by design (rewritten ~weekly) — overwriting is additive.
            let rel = "now.md"
            try writeFile(rel, contents: text)
            try commit([rel], "now: update")
            return rel

        case .rewriteCuratedPage, .promoteTopic, .resolveContradiction,
             .createPerson, .mergeIdentities:
            // Unreachable (guarded above), but keep the switch total + explicit.
            throw WriteError.notAdditive
        }
    }

    // MARK: - Filesystem

    private func absolute(_ rel: String) -> URL { vaultRoot.appendingPathComponent(rel) }

    private func exists(_ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: absolute(rel).path)
    }

    private func writeFile(_ rel: String, contents: String) throws {
        try guardWritable(rel)
        let url = absolute(rel)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.io("write \(rel): \(error.localizedDescription)")
        }
    }

    private func appendLine(_ rel: String, _ line: String) throws {
        try guardWritable(rel)
        let url = absolute(rel)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        do {
            try (existing + sep + line + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.io("append \(rel): \(error.localizedDescription)")
        }
    }

    /// raw/ is immutable except the inbox capture target.
    private func guardWritable(_ rel: String) throws {
        if rel.hasPrefix("raw/") && !rel.hasPrefix("raw/inbox/") {
            throw WriteError.immutable(rel)
        }
    }

    /// A model-supplied page/person name must be a bare filename — never a path.
    private func safeName(_ s: String) throws -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.contains(".."), trimmed != "." else {
            throw WriteError.unsafeName(s)
        }
        return trimmed
    }

    /// Resolve a page title to its vault-relative path by Obsidian's filename convention
    /// (`Title.md`), searching the wiki layer (skips raw/.git/.obsidian). First match wins.
    private func resolvePage(titled name: String) -> String? {
        let target = "\(name).md"
        let skip: Set<String> = ["raw", ".git", ".obsidian"]
        // Canonicalize both sides: the enumerator yields symlink-resolved paths
        // (/var → /private/var on macOS temp dirs), so slicing the raw vaultRoot prefix
        // would leave a stray segment — the same trap BrainIndex hit.
        let rootPath = vaultRoot.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(
            at: vaultRoot, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en {
            if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            if url.lastPathComponent == target {
                let p = url.resolvingSymlinksInPath().path
                guard p.hasPrefix(rootPath) else { return nil }
                return String(p.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            }
        }
        return nil
    }

    // MARK: - Git (explicit paths, atomic per write — never -A)

    private func commit(_ paths: [String], _ message: String) throws {
        try git(["add"] + paths)
        try git(["commit", "-m", message])
        log.info("vault write committed: \(message, privacy: .public)")
    }

    private func git(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", vaultRoot.path] + args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do { try proc.run() } catch {
            throw WriteError.git("launch git: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "git exited \(proc.terminationStatus)"
            throw WriteError.git("git \(args.first ?? "") failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
