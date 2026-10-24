import Foundation

/// The contract between the curation model and the rest of the layer (ADR 0015): the
/// system prompt that asks the 14B for structured proposed writes, and a tolerant parser
/// that turns its reply into `[CurationWrite]`. Pure + total, so the contract is testable
/// without a model — the riskiest seam (free-text → structured writes) gets pinned down.
enum CurationSynthesis {

    /// Instructs the model to emit a single JSON object of proposed writes. The kinds map
    /// 1:1 to `CurationWrite`; the classifier later decides which auto-apply vs. queue.
    static func systemPrompt() -> String {
        """
        You maintain the user's personal knowledge base. Read the conversations and notes \
        below and propose well-supported updates. File the substantive things — people they \
        met, facts about them, decisions, notable articles. Skip pure chit-chat.

        Output a SINGLE JSON object and nothing else: {"writes": [ ... ]}. Each write is a \
        FLAT object with a "kind" string field plus that kind's fields:
        - {"kind":"createPerson","name":"..."}                    a person the user newly met
        - {"kind":"appendTimeline","person":"...","entry":"..."}  a dated fact about a person
        - {"kind":"createSource","title":"...","body":"..."}      a notable article/resource
        - {"kind":"nominateLink","fromPage":"...","toTitle":"..."}
        - {"kind":"captureToInbox","text":"..."}
        - {"kind":"updateNow","text":"..."}
        - {"kind":"promoteTopic","title":"..."}
        - {"kind":"rewriteCuratedPage","title":"...","body":"..."}
        - {"kind":"resolveContradiction","page":"...","detail":"..."}
        - {"kind":"mergeIdentities","into":"...","from":"..."}

        Example output:
        {"writes":[{"kind":"createPerson","name":"Morgan Lee"},\
        {"kind":"appendTimeline","person":"Morgan Lee",\
        "entry":"ExampleCo engineer; reviewed the Sample App demo on 2026-01-15; follow up in February about collaboration."}]}

        For each new contact the user met, emit a createPerson AND an appendTimeline entry \
        for them. Treat a long reference article as one createSource (title + a short \
        summary), not many small writes. If truly nothing is worth filing, return \
        {"writes": []}. Output only the JSON object.
        """
    }

    /// Roughly the input budget that fits the curation model's 8k context with room left
    /// for the system prompt + the JSON output (~4 chars/token ⇒ ~5k tokens of input).
    static let maxInputChars = 20_000

    /// Build the user message from a batch of source texts (stashed conversations + inbox).
    /// Each item is capped, and the batch is truncated to `maxInputChars`, so a few long
    /// meetings can't blow past the context window (which the server would silently truncate
    /// — losing the system prompt's output instructions and timing out on prompt-eval).
    static func userPrompt(items: [String], maxChars: Int = maxInputChars) -> String {
        let perItemCap = max(1_000, maxChars / max(items.count, 1))
        var out = ""
        for (i, item) in items.enumerated() {
            let capped = item.count > perItemCap
                ? String(item.prefix(perItemCap)).trimmingCharacters(in: .whitespaces) + "\n…(truncated)"
                : item
            let block = "## Item \(i + 1)\n\(capped)"
            if out.count + block.count + 2 > maxChars { break }
            out += (out.isEmpty ? "" : "\n\n") + block
        }
        return out
    }

    /// Parse the model's reply into proposed writes. Tolerant of prose or ```json fences
    /// around the object AND of the two write shapes the model emits in practice — the flat
    /// `{"kind":"appendTimeline", ...}` the prompt asks for, and the nested
    /// `{"appendTimeline": {...}}` it often produces instead. Drops malformed entries rather
    /// than throwing (a partial batch beats none, and a garbled write must never reach the
    /// vault). A single nested write must not sink the whole batch — which is exactly what
    /// the old strict decode did, surfacing as "Applied 0, queued 0".
    static func parse(_ raw: String) -> [CurationWrite] {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawWrites = root["writes"] as? [[String: Any]] else {
            return []
        }
        return rawWrites.compactMap { write in
            let flat = flattened(write)
            guard let data = try? JSONSerialization.data(withJSONObject: flat),
                  let dto = try? JSONDecoder().decode(ProposedWrite.self, from: data) else {
                return nil
            }
            return dto.curationWrite()
        }
    }

    /// Normalize a single write into the flat `{"kind": ..., <fields>}` shape `ProposedWrite`
    /// decodes. A nested `{"appendTimeline": {fields}}` (one key whose value is the field
    /// object) is rewritten to `{"kind":"appendTimeline", <fields>}`; an already-flat write
    /// passes through unchanged.
    private static func flattened(_ write: [String: Any]) -> [String: Any] {
        if write["kind"] is String { return write }
        if write.count == 1, let (kind, value) = write.first, let fields = value as? [String: Any] {
            var flat = fields
            flat["kind"] = kind
            return flat
        }
        return write
    }

    // MARK: -

    /// A loosely-typed DTO: every field optional so a missing field drops just that one
    /// write (via `curationWrite()` returning nil), never fails the whole decode.
    private struct ProposedWrite: Decodable {
        let kind: String
        let text, person, entry, title, body: String?
        let fromPage, toTitle, name, page, detail, into, from: String?

        func curationWrite() -> CurationWrite? {
            CurationWrite.make(kind: kind, text: text, person: person, entry: entry,
                               title: title, body: body, fromPage: fromPage, toTitle: toTitle,
                               name: name, page: page, detail: detail, into: into, from: from)
        }
    }

    /// Extract the JSON object: prefer a fenced block, else the outermost `{ … }`.
    static func extractJSONObject(_ s: String) -> String? {
        if let fence = s.range(of: "```json") ?? s.range(of: "```") {
            let after = s[fence.upperBound...]
            if let end = after.range(of: "```") {
                let inner = after[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.hasPrefix("{") { return inner }
            }
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(s[start...end])
    }
}
