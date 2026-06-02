import Foundation
import GRDB

// `localpen` — agent-facing retrieval CLI over the SAME brain index the GUI writes
// (ADR 0014, PLAN-brain.md Phase 5 / decision #9). It opens
// `~/Library/Application Support/Localpen/brain.sqlite` directly through the shared
// `BrainIndex` + `KBSearch` core — no query logic is duplicated, and it works whether
// or not the menu-bar app is running. Purpose: feed Claude Code / terminal agents
// ranked context from the knowledge base (`/cxkb-context` shells out to this).
//
// No argument-parsing dependency (ADR caps SPM deps): the flag grammar is small enough
// to hand-roll. Subcommands: search · get · backlinks · reindex.

// MARK: - Argument grammar

var positional: [String] = []
var json = false
var noReindex = false
var vaultOverride: String?
var limit = 8

do {
    let raw = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < raw.count {
        switch raw[i] {
        case "--json":       json = true
        case "--no-reindex": noReindex = true
        case "--vault":      i += 1; if i < raw.count { vaultOverride = raw[i] }
        case "--limit":      i += 1; if i < raw.count { limit = Int(raw[i]) ?? limit }
        case "-h", "--help": printUsage(); exit(0)
        default:             positional.append(raw[i])
        }
        i += 1
    }
}

guard let command = positional.first else { printUsage(); exit(2) }
let argument = positional.dropFirst().joined(separator: " ")

// MARK: - Vault + index

// vaultRoot only matters when we (re)index. The CLI runs outside the app's
// UserDefaults domain, so honor an explicit override first, then $LOCALPEN_VAULT,
// then the shared default (~/Documents/cxkb).
let vaultRoot: URL = {
    if let v = vaultOverride { return URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }
    if let env = ProcessInfo.processInfo.environment["LOCALPEN_VAULT"], !env.isEmpty {
        return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    return BrainAccess.vaultRoot
}()

let index: BrainIndex
do {
    index = try BrainIndex(config: BrainConfig(vaultRoot: vaultRoot))
} catch {
    fail("could not open the brain index: \(error.localizedDescription)")
}

// Read commands auto-build the index once if it's empty (fresh machine, GUI never run),
// unless --no-reindex. A live/non-empty index is trusted as-is — the GUI's watcher keeps
// it fresh; forcing a rebuild on every query would defeat the point. Use `reindex` to force.
func ensureIndexed() async {
    guard !noReindex else { return }
    if await pageCount() == 0 {
        warn("index empty — building from \(vaultRoot.path) …")
        await index.reindexAll(root: vaultRoot)
    }
}

switch command {
case "search":
    guard !argument.isEmpty else { fail("usage: localpen search \"<query>\"") }
    await ensureIndexed()
    let hits = await KBSearch(dbQueue: index.dbQueue).search(argument, limit: limit)
    emitHits(hits)

case "get":
    guard !argument.isEmpty else { fail("usage: localpen get \"<title>\"") }
    await ensureIndexed()
    guard let page = await index.pageByTitle(argument) else {
        if json { print("null") } else { warn("no page titled \"\(argument)\"") }
        exit(1)
    }
    emitPage(page)

case "backlinks":
    guard !argument.isEmpty else { fail("usage: localpen backlinks \"<title>\"") }
    await ensureIndexed()
    let pages = await index.backlinks(toTitle: argument)
    emitPageList(pages)

case "reindex":
    warn("indexing \(vaultRoot.path) …")
    await index.reindexAll(root: vaultRoot)
    let n = await pageCount()
    if json { print("{\"indexed\":\(n)}") } else { print("indexed \(n) pages") }

case "project":
    // Map a repo path (arg, else cwd) to its cxkb project page + related notes.
    await ensureIndexed()
    let repo = ProjectMatcher.repoName(fromPath: argument)
    print(await LiveKBBackend(index: index).projectContext(repoName: repo))

case "serve":
    // MCP stdio server: speak JSON-RPC over stdin/stdout so agent clients (Claude Code,
    // Cursor) can query the brain as tools. All diagnostics go to stderr (warn) — stdout
    // is the protocol channel and must carry ONLY JSON-RPC. Responses are written via
    // FileHandle so they flush immediately (print() buffers when piped).
    await ensureIndexed()
    warn("localpen MCP server ready (stdio) — \(await pageCount()) pages indexed")
    let server = MCPServer(backend: LiveKBBackend(index: index))
    let stdout = FileHandle.standardOutput
    while let line = readLine(strippingNewline: true) {
        if let response = await server.handle(line) {
            stdout.write(Data((response + "\n").utf8))
        }
    }

default:
    warn("unknown command: \(command)")
    printUsage()
    exit(2)
}

// MARK: - Output

func emitHits(_ hits: [KBHit]) {
    if json {
        emitJSON(hits.map { h -> [String: Any] in
            ["title": h.page.title, "path": rel(h.page.path),
             "area": h.page.area, "type": h.page.type.rawValue,
             "score": h.score, "snippet": snippet(h.page.body)] })
    } else if hits.isEmpty {
        warn("no results")
    } else {
        for h in hits {
            print("\(String(format: "%6.2f", h.score))  \(h.page.title)")
            print("        \(rel(h.page.path))")
            let s = snippet(h.page.body)
            if !s.isEmpty { print("        \(s)") }
        }
    }
}

func emitPage(_ page: KBPage) {
    if json {
        emitJSON(["title": page.title, "path": rel(page.path), "area": page.area,
                  "type": page.type.rawValue, "body": page.body])
    } else {
        print(page.body)
    }
}

func emitPageList(_ pages: [KBPage]) {
    if json {
        emitJSON(pages.map { ["title": $0.title, "path": rel($0.path),
                              "area": $0.area, "type": $0.type.rawValue] })
    } else if pages.isEmpty {
        warn("no backlinks")
    } else {
        for p in pages { print("\(p.title)\n        \(rel(p.path))") }
    }
}

func emitJSON(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                 options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        fail("could not encode JSON")
    }
    print(str)
}

// MARK: - Helpers

/// Page paths are absolute + symlink-canonical; show them relative to the vault for
/// readable output. The vault root is itself canonicalized so the prefix matches.
func rel(_ path: String) -> String {
    let root = vaultRoot.resolvingSymlinksInPath().path
    guard path.hasPrefix(root) else { return path }
    return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
}

/// First line of body, whitespace-collapsed, capped — a one-glance preview.
func snippet(_ body: String, cap: Int = 120) -> String {
    let collapsed = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed.count <= cap ? collapsed
        : collapsed.prefix(cap).trimmingCharacters(in: .whitespaces) + "…"
}

func pageCount() async -> Int {
    (try? await index.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pages") ?? 0
    }) ?? 0
}

func warn(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

func fail(_ msg: String) -> Never {
    warn("error: \(msg)")
    exit(1)
}

func printUsage() {
    warn("""
    localpen — query the Localpen knowledge-base index

    USAGE:
      localpen search "<query>"   [--limit N] [--json]
      localpen get "<title>"      [--json]
      localpen backlinks "<title>" [--json]
      localpen project [<path>]   (repo → its cxkb project page + related; default cwd)
      localpen reindex            [--json]
      localpen serve              (MCP stdio server for Claude Code / Cursor)

    OPTIONS:
      --vault <path>   vault root to index (default: $LOCALPEN_VAULT or ~/Documents/cxkb)
      --no-reindex     never auto-build the index; query whatever exists
      --limit N        max search results (default 8)
      --json           machine-readable output
    """)
}
