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

/// Assembled knowledge context for one ask (ADR 0014). `.text` is the multi-line block
/// injected into the ask prompt — each line pre-prefixed `kb [Title]: …`. Knowledge-only:
/// the `calendar:` line is assembled separately by the existing ask path, so the two stay
/// orthogonal. `.empty` (brain off or nothing relevant) ⇒ no `knowledge` line ⇒ the prompt
/// is byte-identical to a brain-never-existed ask.
struct ContextBundle: Sendable, Equatable {
    let text: String
    let sources: [Provenance]
    let approxTokens: Int

    struct Provenance: Sendable, Equatable, Codable {
        let title: String
        let path: String
        let reason: Reason
        enum Reason: String, Sendable, Codable { case always, query, mention }
    }

    static let empty = ContextBundle(text: "", sources: [], approxTokens: 0)
}

extension ContextBundle.Provenance {
    /// JSON-encode a provenance list for thread persistence. nil for empty (stored NULL).
    static func encode(_ list: [ContextBundle.Provenance]) -> String? {
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a stored provenance JSON string; [] on nil/garbage (fail-soft on resume).
    static func decode(_ json: String?) -> [ContextBundle.Provenance] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ContextBundle.Provenance].self, from: data)
        else { return [] }
        return list
    }
}
