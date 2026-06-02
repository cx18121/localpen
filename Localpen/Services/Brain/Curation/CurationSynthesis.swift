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
        You maintain Charlie's personal knowledge base. Read the conversations and notes \
        below and propose ONLY well-supported updates. Be conservative: when in doubt, \
        propose nothing.

        Output a SINGLE JSON object and nothing else: {"writes": [ ... ]}. Each entry has a \
        "kind" and fields:
        - captureToInbox {text}
        - appendTimeline {person, entry}      (only for a person already in the base)
        - createSource {title, body}
        - nominateLink {fromPage, toTitle}
        - updateNow {text}
        - createPerson {name}                  (a genuinely new person)
        - promoteTopic {title}
        - rewriteCuratedPage {title, body}
        - resolveContradiction {page, detail}
        - mergeIdentities {into, from}

        If nothing is worth filing, return {"writes": []}. Output only the JSON object.
        """
    }

    /// Build the user message from a batch of source texts (stashed conversations + inbox).
    static func userPrompt(items: [String]) -> String {
        items.enumerated()
            .map { "## Item \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
    }

    /// Parse the model's reply into proposed writes. Tolerant of prose or ```json fences
    /// around the object; drops malformed entries rather than throwing (a partial batch is
    /// better than none, and a garbled write must never reach the vault).
    static func parse(_ raw: String) -> [CurationWrite] {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return []
        }
        return envelope.writes.compactMap { $0.curationWrite() }
    }

    // MARK: -

    private struct Envelope: Decodable { let writes: [ProposedWrite] }

    /// A loosely-typed DTO: every field optional so a missing field drops just that one
    /// write (via `curationWrite()` returning nil), never fails the whole decode.
    private struct ProposedWrite: Decodable {
        let kind: String
        let text, person, entry, title, body: String?
        let fromPage, toTitle, name, page, detail, into, from: String?

        func curationWrite() -> CurationWrite? {
            switch kind {
            case "captureToInbox":      return text.map(CurationWrite.captureToInbox)
            case "updateNow":           return text.map(CurationWrite.updateNow)
            case "createPerson":        return name.map(CurationWrite.createPerson)
            case "promoteTopic":        return title.map(CurationWrite.promoteTopic)
            case "appendTimeline":
                guard let person, let entry else { return nil }
                return .appendTimeline(person: person, entry: entry)
            case "createSource":
                guard let title, let body else { return nil }
                return .createSource(title: title, body: body)
            case "nominateLink":
                guard let fromPage, let toTitle else { return nil }
                return .nominateLink(fromPage: fromPage, toTitle: toTitle)
            case "rewriteCuratedPage":
                guard let title, let body else { return nil }
                return .rewriteCuratedPage(title: title, body: body)
            case "resolveContradiction":
                guard let page, let detail else { return nil }
                return .resolveContradiction(page: page, detail: detail)
            case "mergeIdentities":
                guard let into, let from else { return nil }
                return .mergeIdentities(into: into, from: from)
            default:                    return nil
            }
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
