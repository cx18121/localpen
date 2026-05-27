import Foundation

final class StreamingClient {
    let port: Int

    init(port: Int) {
        self.port = port
    }

    static func requestBody(messages: [(role: String, content: String)],
                            sampling: ModelDescriptor.Sampling?) -> [String: Any] {
        [
            "model": "local",
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "temperature": sampling?.temperature ?? 0.4,
            "top_p": sampling?.topP ?? 0.9,
            "repeat_penalty": sampling?.repeatPenalty ?? 1.05
        ]
    }

    func complete(
        systemPrompt: String,
        userText: String,
        sampling: ModelDescriptor.Sampling? = nil
    ) -> AsyncThrowingStream<String, Error> {
        complete(messages: [("system", systemPrompt), ("user", userText)], sampling: sampling)
    }

    func complete(messages: [(role: String, content: String)],
                  sampling: ModelDescriptor.Sampling? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Capture producer task so consumer cancellation tears down the
            // underlying URLSession request (otherwise llama-server keeps
            // generating after we stop reading).
            let producer = Task {
                do {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(self.port)/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.requestBody(messages: messages, sampling: sampling))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw NSError(domain: "Localpen", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "llama-server returned HTTP \(http.statusCode)"])
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
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
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}
