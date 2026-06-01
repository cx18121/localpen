import Foundation

/// A vault page's kind, from its `type:` frontmatter (with the journal-filename
/// override applied by `MarkdownParser`). Unknown/absent ⇒ `.note`.
enum KBPageType: String, Sendable, Equatable {
    case journal, project, topic, source
    case self_ = "self"
    case person, note, area, now

    init(frontmatter raw: String?) {
        self = raw.flatMap(KBPageType.init(rawValue:)) ?? .note
    }
}

/// A markdown page reduced to exactly what the brain indexes (ADR 0014). The vault
/// file is the source of truth; this is the parsed projection of one file.
struct KBPage: Sendable, Equatable {
    let path: String                 // absolute path — stable primary key
    let title: String                // filename without `.md` (== wikilink target form)
    let type: KBPageType
    let area: String                 // first path component under the vault root ("" = root file)
    let body: String                 // frontmatter-stripped markdown
    let outboundLinks: [String]      // normalized [[targets]], de-duped, in order
    let tags: [String]
    let mtime: Date
    let frontmatter: [String: String]
}

/// Brain indexing + context-assembly knobs (ADR 0014). All defaults are config, not
/// magic constants — tune in one place. `vaultRoot` is the indexed root; the actual
/// reindex always takes its root explicitly, so this is the app's pointer, not a lock.
struct BrainConfig: Sendable {
    var vaultRoot: URL
    var alwaysIncludeAreas: Set<String> = ["self"]
    var alwaysIncludeFiles: Set<String> = ["now.md"]   // matched by title (drop `.md`); included only if present
    var excludedDirComponents: Set<String> = [".obsidian", ".git", "raw"]
    var topK: Int = 6
    var maxContextTokens: Int = 1200
    var perPageCharCap: Int = 800

    static var `default`: BrainConfig { BrainConfig(vaultRoot: BrainAccess.vaultRoot) }
}
