import Foundation

/// A short reply Claude wrote in one go (`ClaudeClient.quickAnswer`).
public struct ClaudeQuickAnswer: Sendable, Equatable {
    /// The reply's text, as written.
    public let text: String
    /// Claude ended on its own: false when the reply hit `max_tokens` or was declined.
    public let finished: Bool
}

extension ClaudeClient {
    /// One short reply in a single request, for small jobs beside the assistant's turns (a typed note's title).
    ///
    /// `prompt` goes as the only user message under `system`. Nothing streams and nothing is retried; no tools, no
    /// web search, thinking disabled at low effort (Haiku 5.5 accepts that pair), and the whole request gives up after
    /// `timeout`. Same key and API version as the replies, always on Claude Haiku 5.5 (`ClaudeConfiguration.model`)
    /// whichever model answers, and no sampling parameters or prefill (API version 2026-10-21 rejects them).
    ///
    /// Throws `ClaudeError`. `label` names the job in the log ("note title"): one line with the outcome, the time and
    /// the token counts, never the prompt or the reply.
    public func quickAnswer(to prompt: String, system: String, label: String, maxTokens: Int = 32,
                            timeout: TimeInterval = 8) async throws -> ClaudeQuickAnswer {
        do {
            return try await withThrowingTaskGroup(of: ClaudeQuickAnswer.self) { group in
                group.addTask {
                    try await self.quickRequest(prompt: prompt, system: system, label: label, maxTokens: maxTokens,
                                                timeout: timeout)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw ClaudeError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw ClaudeError.cancelled }
                return first
            }
        } catch {
            let mapped = Self.map(error)
            if mapped != .cancelled { AssistantLog.add("Claude \(label) failed: \(mapped.logKind)") }
            throw mapped
        }
    }

    private func quickRequest(prompt: String, system: String, label: String, maxTokens: Int,
                              timeout: TimeInterval) async throws -> ClaudeQuickAnswer {
        let key: String
        do {
            guard let saved = try keyProvider() else { throw ClaudeError.noKey }
            key = saved
        } catch KeyStoreError.locked {
            throw ClaudeError.keyLocked
        }
        let body: JSONValue = [
            "model": .string(configuration.model),
            "max_tokens": .int(maxTokens),
            "thinking": ["type": .string(ThinkingMode.disabled.rawValue)],
            "output_config": ["effort": .string(Effort.low.rawValue)],
            "system": .string(system),
            "messages": [["role": "user", "content": .string(prompt)]],
        ]
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = try body.encoded()
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        apply(key: key, to: &request)

        let watch = Stopwatch()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONValue.parse(data)
        guard status == 200 else {
            throw Self.quickError(status: status, type: json?["error"]?["type"]?.string ?? "unknown",
                                  message: json?["error"]?["message"]?.string ?? "")
        }
        guard let json, let content = json["content"]?.array else { throw ClaudeError.streamBroken }
        let text = content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
        let stop = json["stop_reason"]?.string
        let usage = json["usage"]
        AssistantLog.add("Claude \(label) done (\(stop ?? "no stop reason")) in \(watch.elapsed.seconds); "
                         + "\(usage?["input_tokens"]?.int ?? 0) in, \(usage?["output_tokens"]?.int ?? 0) out")
        return ClaudeQuickAnswer(text: text, finished: stop == "end_turn" || stop == "stop_sequence")
    }

    /// An HTTP error, sorted the same way as the replies' errors.
    private static func quickError(status: Int, type: String, message: String) -> ClaudeError {
        switch status {
        case 400: return .badRequest(message)
        case 401: return .unauthorized
        case 402: return .billing
        case 403: return .forbidden
        case 404: return .modelNotFound
        case 429: return .rateLimited
        case 529: return .overloaded
        default: return type == "overloaded_error" ? .overloaded : .serverError(status)
        }
    }
}
