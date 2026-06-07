import Foundation

/// Client for a local `llama-server --embeddings` (EmbeddingGemma). Encapsulates the
/// ADR-0023 model-version contract: model id, dim, pooling, and the query/document
/// task-prefixes. These constants are the shared interface with cx-news — keep in lockstep.
struct EmbeddingService {
    enum Kind { case query, document }

    static let modelID = "embeddinggemma-300m"
    static let dim = 256                       // Matryoshka-truncated
    let endpoint: URL                          // e.g. http://127.0.0.1:11435/embedding

    init(port: Int = 11435) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/embedding")!
    }

    /// EmbeddingGemma requires task prefixes; mismatched prefixes degrade quality.
    static func prefixed(_ text: String, kind: Kind) -> String {
        switch kind {
        case .query:    return "task: search result | query: \(text)"
        case .document: return "title: none | text: \(text)"
        }
    }

    static func decode(_ data: Data) throws -> [Float] {
        struct Item: Decodable { let embedding: [Float] }
        let items = try JSONDecoder().decode([Item].self, from: data)
        guard let first = items.first else {
            throw NSError(domain: "Localpen", code: 110,
                          userInfo: [NSLocalizedDescriptionKey: "empty embedding response"])
        }
        return Array(first.embedding.prefix(dim))     // enforce the contract dim
    }

    func embed(_ text: String, kind: Kind) async throws -> [Float] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["content": Self.prefixed(text, kind: kind)])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Localpen", code: 111,
                          userInfo: [NSLocalizedDescriptionKey: "embedding server not OK"])
        }
        return try Self.decode(data)
    }
}
