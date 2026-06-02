import Foundation

/// A minimal MCP (Model Context Protocol) stdio server exposing the brain's read API to
/// agent clients like Claude Code / Cursor (PLAN-brain.md Phase 5 — the "feed my agents"
/// goal). Speaks newline-delimited JSON-RPC 2.0; `localpen serve` wraps it over the same
/// `KBSearch`/`BrainIndex` core as the CLI.
///
/// The protocol handling is isolated here (pure dispatch over a `KBQuerying` backend) so it
/// unit-tests against an in-memory index without spawning a process. `main.swift` only wires
/// the live backend + the stdin loop.
struct MCPServer {
    let backend: KBQuerying
    var name = "localpen"
    var version = "0.1.0"
    var protocolVersion = "2024-11-05"

    /// Handle one JSON-RPC line. Returns the response JSON string, or nil for notifications
    /// and unparseable input (notifications get no reply per JSON-RPC).
    func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = msg["method"] as? String else {
            return nil
        }
        let id = msg["id"]   // Int | String | absent (notification)

        switch method {
        case "initialize":
            return success(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ])
        case "tools/list":
            return success(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let text = await callTool(toolName, args: args)
            return success(id: id, result: ["content": [["type": "text", "text": text]]])
        case _ where method.hasPrefix("notifications/"):
            return nil   // notifications/initialized, /cancelled, … — no reply
        default:
            return failure(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "kb_search",
            "description": "Search Charlie's personal knowledge base (cxkb). Returns ranked pages with a snippet. Use to find notes, projects, people, meetings, or prior decisions.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "free-text search query"],
                    "limit": ["type": "integer", "description": "max results (default 8)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "kb_get",
            "description": "Fetch the full markdown body of a knowledge-base page by its exact title.",
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string", "description": "page title (filename without .md)"]],
                "required": ["title"],
            ],
        ],
        [
            "name": "kb_backlinks",
            "description": "List the pages that link to a given page title — the wikilink graph around it.",
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string"]],
                "required": ["title"],
            ],
        ],
    ]

    private func callTool(_ name: String, args: [String: Any]) async -> String {
        switch name {
        case "kb_search":
            let query = args["query"] as? String ?? ""
            let limit = (args["limit"] as? Int) ?? 8
            let hits = await backend.search(query, limit: limit)
            guard !hits.isEmpty else { return "No results." }
            return hits.map { "## \($0.page.title)\n\($0.page.path)\n\(Self.snippet($0.page.body))" }
                .joined(separator: "\n\n")
        case "kb_get":
            let title = args["title"] as? String ?? ""
            guard let page = await backend.page(title: title) else { return "No page titled \"\(title)\"." }
            return page.body
        case "kb_backlinks":
            let title = args["title"] as? String ?? ""
            let pages = await backend.backlinks(title: title)
            guard !pages.isEmpty else { return "No backlinks to \"\(title)\"." }
            return pages.map { "- \($0.title) (\($0.path))" }.joined(separator: "\n")
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - JSON-RPC framing

    private func success(id: Any?, result: [String: Any]) -> String {
        encode(envelope(id: id, payload: ["result": result]))
    }

    private func failure(id: Any?, code: Int, message: String) -> String {
        encode(envelope(id: id, payload: ["error": ["code": code, "message": message]]))
    }

    private func envelope(id: Any?, payload: [String: Any]) -> [String: Any] {
        var obj: [String: Any] = ["jsonrpc": "2.0"]
        obj["id"] = id ?? NSNull()   // echo the request id (null if somehow absent)
        payload.forEach { obj[$0] = $1 }
        return obj
    }

    private func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#
        }
        return str
    }

    static func snippet(_ body: String, cap: Int = 200) -> String {
        let collapsed = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count <= cap ? collapsed
            : collapsed.prefix(cap).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The read surface the MCP server needs — implemented live over `BrainIndex`/`KBSearch`,
/// faked in tests. Keeps `MCPServer` free of GRDB so its dispatch is pure-testable.
protocol KBQuerying {
    func search(_ query: String, limit: Int) async -> [KBHit]
    func page(title: String) async -> KBPage?
    func backlinks(title: String) async -> [KBPage]
}

/// Live backend: the same index + ranking the GUI and CLI use.
struct LiveKBBackend: KBQuerying {
    let index: BrainIndex
    func search(_ query: String, limit: Int) async -> [KBHit] {
        await KBSearch(dbQueue: index.dbQueue).search(query, limit: limit)
    }
    func page(title: String) async -> KBPage? { await index.pageByTitle(title) }
    func backlinks(title: String) async -> [KBPage] { await index.backlinks(toTitle: title) }
}
