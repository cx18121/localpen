import Foundation
import GRDB

/// One inbox message. Headers (sender/subject/date) come from the Envelope Index cheaply;
/// `body` is loaded on demand (`MailStoreReading.body`) only when a row is expanded or
/// attached — so listing recent/searched mail never reads `.emlx` files.
struct MailMessage: Identifiable, Equatable, Sendable {
    let id: Int64        // messages.ROWID — also the `<ROWID>.emlx` filename
    let sender: String
    let subject: String
    let date: Date
    var body: String?
}

/// Read-only access to the local Apple Mail store for the `+ Mail` picker (ADR 0020 +
/// the mail-is-retrieval reframe): recent inbox by time window, search by sender/subject,
/// and a single message's body on demand. A `Sendable` seam so the picker is testable
/// without a live store.
protocol MailStoreReading: Sendable {
    /// Inbox messages received at/after `sinceEpoch` (unix seconds), newest first. Headers only.
    func recentInbox(sinceEpoch: Double, limit: Int) -> [MailMessage]
    /// Inbox messages whose sender or subject matches `query`, newest first. Headers only.
    func search(_ query: String, limit: Int) -> [MailMessage]
    /// The capped plain-text body of one message, read from its `.emlx`. "" if unavailable.
    func body(forID id: Int64, charCap: Int) -> String
    /// Bodies for many messages in ONE filesystem pass (for the search-index build) — far
    /// cheaper than N calls to `body`, each of which scans the store. Missing ⇒ absent.
    func bodies(forIDs ids: [Int64], charCap: Int) -> [Int64: String]
}

/// Build the `<context>` block for a set of attached messages (sender / subject / date +
/// body). Shared by the picker-confirm path and tests so the format can't drift.
enum MailContextFormatter {
    static func block(_ messages: [MailMessage]) -> String {
        messages.map { m in
            let subject = m.subject.isEmpty ? "(no subject)" : m.subject
            let head = "- \(m.sender) — \(subject) (\(dateFormatter.string(from: m.date)))"
            let body = (m.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? head : "\(head)\n\(body)"
        }.joined(separator: "\n")
    }

    /// A markdown note for promoting an email into the cxkb inbox (raw/inbox/), where the
    /// dream cycle can fold it into people/topics. Frontmatter carries `mail_id` for
    /// traceability + dedup; the body is the MIME-extracted text.
    static func cxkbNote(_ m: MailMessage, body: String) -> String {
        let subject = m.subject.isEmpty ? "(no subject)" : m.subject
        return """
        ---
        type: email
        from: \(yaml(m.sender))
        subject: \(yaml(subject))
        date: \(isoDate.string(from: m.date))
        mail_id: \(m.id)
        source: mail
        ---

        # \(subject)

        From: \(m.sender) · \(displayDate.string(from: m.date))

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func yaml(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()
    private static let isoDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let displayDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
}

/// Production reader: opens the `Envelope Index` SQLite **read-only**, joins `labels` →
/// INBOX mailboxes (the Gmail-correct way), and resolves bodies from `<ROWID>.emlx`.
struct SystemMailStoreReader: MailStoreReading {

    // Shared SELECT for the header columns + inbox/active filter; callers append a
    // predicate, ordering, and LIMIT.
    private static let headerSelect = """
        SELECT m.ROWID AS id, s.subject AS subject,
               a.address AS address, a.comment AS comment,
               m.date_received AS date
        FROM messages m
        JOIN labels l ON l.message_id = m.ROWID
        JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE l.mailbox_id IN (SELECT ROWID FROM mailboxes WHERE url LIKE '%/INBOX')
          AND m.deleted = 0
        """

    func recentInbox(sinceEpoch: Double, limit: Int) -> [MailMessage] {
        fetch(predicate: "AND m.date_received >= ?", args: [sinceEpoch, limit])
    }

    func search(_ query: String, limit: Int) -> [MailMessage] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return fetch(
            predicate: "AND (s.subject LIKE '%'||?||'%' OR a.address LIKE '%'||?||'%' OR a.comment LIKE '%'||?||'%')",
            args: [q, q, q, limit])
    }

    func body(forID id: Int64, charCap: Int) -> String {
        guard let storeURL = MailAccess.storeURL() else { return "" }
        let versionRoot = storeURL.deletingLastPathComponent().deletingLastPathComponent()
        guard let url = Self.locateEmlx(rowids: [id], under: versionRoot)[id],
              let data = try? Data(contentsOf: url) else { return "" }
        return EmlxParser.bodyText(data, charCap: charCap)
    }

    func bodies(forIDs ids: [Int64], charCap: Int) -> [Int64: String] {
        guard !ids.isEmpty, let storeURL = MailAccess.storeURL() else { return [:] }
        let versionRoot = storeURL.deletingLastPathComponent().deletingLastPathComponent()
        let paths = Self.locateEmlx(rowids: ids, under: versionRoot)   // one scan for all ids
        var out: [Int64: String] = [:]
        for (id, url) in paths {
            if let data = try? Data(contentsOf: url) {
                out[id] = EmlxParser.bodyText(data, charCap: charCap)
            }
        }
        return out
    }

    // MARK: - shared query

    private func fetch(predicate: String, args: [DatabaseValueConvertible]) -> [MailMessage] {
        guard let storeURL = MailAccess.storeURL() else { return [] }
        var config = Configuration()
        config.readonly = true
        guard let dbQueue = try? DatabaseQueue(path: storeURL.path, configuration: config) else {
            return []
        }
        let sql = "\(Self.headerSelect) \(predicate) ORDER BY m.date_received DESC LIMIT ?"
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }) ?? []
        return rows.map { row in
            let comment: String? = row["comment"]
            let address: String? = row["address"]
            let sender = (comment?.isEmpty == false ? comment : address) ?? "unknown sender"
            return MailMessage(id: row["id"], sender: sender, subject: row["subject"] ?? "",
                               date: Date(timeIntervalSince1970: row["date"] ?? 0), body: nil)
        }
    }

    /// Locate `<ROWID>.emlx` (or `.partial.emlx`) for each id in one enumerator pass.
    /// Path can't be computed (Mail shards `Data/Messages/` into `Data/N/M/Messages/`),
    /// so we search; the tree is small (~20k files, ~80ms full scan) and we stop early.
    static func locateEmlx(rowids: [Int64], under root: URL) -> [Int64: URL] {
        var targets: [String: Int64] = [:]
        for id in rowids {
            targets["\(id).emlx"] = id
            targets["\(id).partial.emlx"] = id
        }
        var found: [Int64: URL] = [:]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return found }
        for case let url as URL in en {
            guard let id = targets[url.lastPathComponent] else { continue }
            if found[id] == nil || !url.lastPathComponent.contains(".partial.") {
                found[id] = url
            }
            if found.count == rowids.count,
               rowids.allSatisfy({ found[$0]?.lastPathComponent.contains(".partial.") == false }) {
                break
            }
        }
        return found
    }
}
