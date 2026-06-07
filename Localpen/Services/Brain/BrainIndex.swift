import Foundation
import GRDB
import os

/// Derived FTS5 index over the Obsidian vault (ADR 0014). `brain.sqlite` is a
/// rebuildable cache — the markdown is the source of truth, so a schema change is
/// "delete + reindex", never a data migration. Mirrors `Persistence`'s GRDB stack
/// (DatabaseQueue + versioned migrator + `testInMemory` ctor).
///
/// Three tables: `pages` (row-of-record, stable `path` key, `rowid` = FTS/embeddings
/// join key), a contentless-external `pages_fts` for bm25 ranking, and `links` +
/// precomputed `backlinks` for the wikilink graph. FTS sync is explicit in the
/// upsert/delete paths (no triggers) — matches the codebase's visible-SQL preference.
final class BrainIndex {
    let dbQueue: DatabaseQueue
    private let config: BrainConfig
    private let parser: MarkdownParsing
    private let log = Logger(subsystem: "app.localpen.Localpen", category: "BrainIndex")

    init(config: BrainConfig = .default, parser: MarkdownParsing = MarkdownParser()) throws {
        let dbPath = Self.databasePath()
        let queue = try DatabaseQueue(path: dbPath.path)
        try Self.migrate(queue)
        self.dbQueue = queue
        self.config = config
        self.parser = parser
        log.info("BrainIndex ready at \(dbPath.path, privacy: .public)")
    }

    /// Test-only in-memory queue (mirrors `Persistence.init(testInMemory:)`). Tests
    /// pass their temp vault root straight to `reindexAll(root:)`, so the default
    /// config's `vaultRoot` is irrelevant under test.
    init(testInMemory: Bool, parser: MarkdownParsing = MarkdownParser()) throws {
        precondition(testInMemory)
        let queue = try DatabaseQueue()
        try Self.migrate(queue)
        self.dbQueue = queue
        self.config = .default
        self.parser = parser
    }

    // MARK: - Indexing

    /// Full rebuild: enumerate the vault, parse changed files (mtime fast-path),
    /// upsert, prune rows whose file is gone, then recompute the graph. Idempotent.
    func reindexAll(root: URL) async {
        let urls = Self.enumerateMarkdown(root: root, excluding: config.excludedDirComponents)
        let known: [String: Double] = (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT path, mtime FROM pages").reduce(into: [:]) {
                $0[$1["path"] as String] = $1["mtime"] as Double
            }
        }) ?? [:]

        var seen = Set<String>()
        for raw in urls {
            let url = raw.resolvingSymlinksInPath()   // match the parser's canonical path key
            seen.insert(url.path)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if let m = known[url.path], m == mtime { continue }   // unchanged → skip parse
            if let page = parser.parse(url: url, vaultRoot: root) { await upsert(page) }
        }
        for stale in Set(known.keys).subtracting(seen) {
            await removeRow(URL(fileURLWithPath: stale))
        }
        await recomputeGraph()
    }

    /// Incremental single-file update (what `KBWatcher` calls): re-parse + upsert, or
    /// remove if the file is gone, then recompute the graph.
    func reindex(path rawURL: URL) async {
        let url = rawURL.resolvingSymlinksInPath()
        if let page = parser.parse(url: url, vaultRoot: config.vaultRoot) { await upsert(page) }
        else { await removeRow(url) }
        await recomputeGraph()
    }

    func remove(_ rawURL: URL) async {
        await removeRow(rawURL.resolvingSymlinksInPath())
        await recomputeGraph()
    }

    // MARK: - Read API (ContextEngine + future People mode)

    /// `self/`-area pages + named always-files (e.g. `now.md`), de-duped by path.
    func alwaysPages(areas: Set<String>, files: Set<String>) async -> [KBPage] {
        let titles = files.map { ($0 as NSString).deletingPathExtension }
        return (try? await dbQueue.read { db -> [KBPage] in
            var rows: [Row] = []
            if !areas.isEmpty {
                let qs = areas.map { _ in "?" }.joined(separator: ",")
                rows += try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE area IN (\(qs))",
                                         arguments: StatementArguments(Array(areas)))
            }
            if !titles.isEmpty {
                let qs = titles.map { _ in "?" }.joined(separator: ",")
                rows += try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE title IN (\(qs))",
                                         arguments: StatementArguments(titles))
            }
            var seen = Set<String>()
            return rows.compactMap { row in
                let p = KBPage(brainRow: row)
                return seen.insert(p.path).inserted ? p : nil
            }
        }) ?? []
    }

    func pageByTitle(_ title: String) async -> KBPage? {
        let row = try? await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pages WHERE title = ? COLLATE NOCASE LIMIT 1",
                             arguments: [title])
        }
        return (row ?? nil).map(KBPage.init(brainRow:))
    }

    /// Pages that link *to* `title` (its backlinks).
    func backlinks(toTitle title: String) async -> [KBPage] {
        (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.* FROM pages p
                JOIN links l ON l.src_path = p.path
                WHERE l.dst_title = ? COLLATE NOCASE
                """, arguments: [title]).map(KBPage.init(brainRow:))
        }) ?? []
    }

    func recentPages(limit: Int) async -> [KBPage] {
        (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pages ORDER BY mtime DESC LIMIT ?",
                             arguments: [limit]).map(KBPage.init(brainRow:))
        }) ?? []
    }

    /// All pages of a given type (e.g. every `project` page) — for project-aware recall.
    func pages(ofType type: KBPageType) async -> [KBPage] {
        (try? await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE type = ?",
                             arguments: [type.rawValue]).map(KBPage.init(brainRow:))
        }) ?? []
    }

    // MARK: - Internals

    /// Keep `pages` and the contentless-external `pages_fts` in lockstep, then rewrite
    /// this page's outbound links (resolved to a `dst_path` when the target exists).
    private func upsert(_ page: KBPage) async {
        let tagsJoined = page.tags.joined(separator: " ")
        let fmJSON = (try? String(decoding: JSONSerialization.data(withJSONObject: page.frontmatter), as: UTF8.self)) ?? "{}"
        try? await dbQueue.write { db in
            if let e = try Row.fetchOne(db, sql: "SELECT rowid, title, body, tags FROM pages WHERE path = ?", arguments: [page.path]) {
                // Contentless-external FTS5 delete idiom: feed the OLD values back.
                try db.execute(sql: "INSERT INTO pages_fts(pages_fts, rowid, title, body, tags) VALUES('delete', ?, ?, ?, ?)",
                               arguments: [e["rowid"], e["title"], e["body"], e["tags"]])
            }
            try db.execute(sql: """
                INSERT INTO pages(path,title,type,area,body,tags,mtime,frontmatter_json)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(path) DO UPDATE SET
                  title=excluded.title, type=excluded.type, area=excluded.area,
                  body=excluded.body, tags=excluded.tags, mtime=excluded.mtime,
                  frontmatter_json=excluded.frontmatter_json
                """, arguments: [page.path, page.title, page.type.rawValue, page.area,
                                 page.body, tagsJoined, page.mtime.timeIntervalSince1970, fmJSON])
            let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM pages WHERE path = ?", arguments: [page.path])!
            try db.execute(sql: "INSERT INTO pages_fts(rowid, title, body, tags) VALUES(?,?,?,?)",
                           arguments: [rowid, page.title, page.body, tagsJoined])

            try db.execute(sql: "DELETE FROM links WHERE src_path = ?", arguments: [page.path])
            for target in page.outboundLinks {
                let dst = try String.fetchOne(db, sql: "SELECT path FROM pages WHERE title = ? COLLATE NOCASE", arguments: [target])
                try db.execute(sql: "INSERT INTO links(src_path, dst_title, dst_path) VALUES(?,?,?)",
                               arguments: [page.path, target, dst])
            }
        }
    }

    private func removeRow(_ url: URL) async {
        try? await dbQueue.write { db in
            guard let e = try Row.fetchOne(db, sql: "SELECT rowid, title, body, tags FROM pages WHERE path = ?", arguments: [url.path]) else { return }
            try db.execute(sql: "INSERT INTO pages_fts(pages_fts, rowid, title, body, tags) VALUES('delete', ?, ?, ?, ?)",
                           arguments: [e["rowid"], e["title"], e["body"], e["tags"]])
            try db.execute(sql: "DELETE FROM pages WHERE path = ?", arguments: [url.path])   // cascades links
        }
    }

    /// Resolve any danglers now satisfied by a freshly-created page, then recompute
    /// the per-title in-degree table. Whole-pass — cheap at vault scale (~88 files).
    private func recomputeGraph() async {
        try? await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE links SET dst_path =
                  (SELECT p.path FROM pages p WHERE p.title = links.dst_title COLLATE NOCASE)
                WHERE dst_path IS NULL
                """)
            try db.execute(sql: "DELETE FROM backlinks")
            try db.execute(sql: """
                INSERT INTO backlinks(title, indegree)
                SELECT dst_title, COUNT(*) FROM links GROUP BY dst_title COLLATE NOCASE
                """)
        }
    }

    // MARK: - Static

    static func enumerateMarkdown(root: URL, excluding: Set<String>) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.pathComponents.contains(where: { excluding.contains($0) }) { continue }
            if url.pathExtension.lowercased() == "md" { out.append(url) }
        }
        return out
    }

    static func databasePath() -> URL {
        AppSupport.root().appendingPathComponent("brain.sqlite")
    }

    static func migrate(_ queue: DatabaseQueue) throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1.brain") { db in
            try db.create(table: "pages") { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("path", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("type", .text).notNull()
                t.column("area", .text).notNull()
                t.column("body", .text).notNull()
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("mtime", .double).notNull()
                t.column("frontmatter_json", .text).notNull().defaults(to: "{}")
            }
            try db.create(indexOn: "pages", columns: ["title"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE pages_fts USING fts5(
                    title, body, tags,
                    content='pages', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)

            try db.create(table: "links") { t in
                t.column("src_path", .text).notNull()
                    .references("pages", column: "path", onDelete: .cascade)
                t.column("dst_title", .text).notNull()
                t.column("dst_path", .text)
            }
            try db.create(indexOn: "links", columns: ["dst_title"])
            try db.create(indexOn: "links", columns: ["src_path"])

            try db.create(table: "backlinks") { t in
                t.column("title", .text).notNull().primaryKey()
                t.column("indegree", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v2.page_embeddings") { db in
            try db.create(table: "page_embeddings") { t in
                t.column("path", .text).primaryKey()
                    .references("pages", column: "path", onDelete: .cascade)
                t.column("vector", .blob).notNull()
                t.column("dim", .integer).notNull()
                t.column("model", .text).notNull()
            }
        }
        try m.migrate(queue)
    }
}

extension KBPage {
    /// Reconstruct from a `pages` row. `outboundLinks` is intentionally empty — the
    /// wikilink graph lives in `links`/`backlinks`, and nothing downstream of indexing
    /// reads a read-back page's outbound links.
    init(brainRow row: Row) {
        let fmJSON: String = row["frontmatter_json"] ?? "{}"
        let fm = ((try? JSONSerialization.jsonObject(with: Data(fmJSON.utf8))) as? [String: String]) ?? [:]
        let tagsStr: String = row["tags"] ?? ""
        self.init(
            path: row["path"],
            title: row["title"],
            type: KBPageType(rawValue: row["type"]) ?? .note,
            area: row["area"],
            body: row["body"],
            outboundLinks: [],
            tags: tagsStr.split(separator: " ").map(String.init),
            mtime: Date(timeIntervalSince1970: row["mtime"]),
            frontmatter: fm
        )
    }
}
