import Foundation

final class StreamingClient {
    let port: Int

    init(port: Int) {
        self.port = port
    }

    func complete(systemPrompt: String, userText: String, temperature: Double = 0.4) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60

                    let body: [String: Any] = [
                        "model": "local",
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userText]
                        ],
                        "stream": true,
                        "temperature": temperature
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(domain: "Localpen", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "llama-server returned HTTP \(http.statusCode)"])
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
