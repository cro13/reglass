import Foundation

/// Claude over raw HTTPS with server-sent events (Swift has no official SDK), on the model the owner chose
/// (`ClaudeModel`, pinned per conversation).
///
/// One stream per request. Anthropic's server-side web search and web fetch run inside it: when the server pauses a
/// long turn (`pause_turn`), the paused assistant content is sent back unchanged and the server carries on. The
/// iPhone's own tools ("client tools") end the stream with `stop_reason: tool_use` (`ClaudeCompletion.Stop.toolUse`);
/// the caller (`TurnRunner`) runs them, appends the results and calls `continueAfterTools`. Failures are retried by
/// class (rate limits, overload, server errors, flaky networks), but only while the request has streamed nothing yet,
/// so a half-spoken reply is never repeated.
///
/// Request shape (see `body(…)`): `model`, `max_tokens`, `stream`, `thinking` and `output_config: {effort}` (per
/// route, see `AssistantTuning`; how each model turns thinking off is `ClaudeModel.thinking`), `fallbacks: "default"`
/// on the models that have Anthropic's server-side fallback, `tools` (web search, web fetch, then the client tools
/// sorted by name; see `ClientTools`), a cached system prompt, and a user turn made of a context note (date, time
/// zone) plus the transcript. The cache breakpoint on the system prompt covers the tools too (they render first). No
/// temperature/top_p/top_k, no prefill and no forced `tool_choice`: API version 2026-10-21 rejects the first, these
/// models reject prefill and forced tool choice, and a forced call would skip thinking.
///
/// Logs carry status codes, error kinds, timings and token counts only.
public final class ClaudeClient: @unchecked Sendable {
    public let configuration: ClaudeConfiguration
    let keyProvider: @Sendable () throws -> String?
    let session: URLSession
    private let searchTool = WebSearchToolChoice()
    private let fetchTool = WebFetchToolChoice()
    private let clientTools = ClientTools()
    private let serverFallback = ServerFallbackChoice()
    private let warmLock = NSLock()
    private var lastWarm: Date?

    public init(configuration: ClaudeConfiguration = ClaudeConfiguration(), keys: KeyStore = .shared) {
        self.configuration = configuration
        self.keyProvider = { try keys.read(.anthropic) }
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration.idleTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.deadline + 30
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: sessionConfiguration)
    }

    // MARK: Replies

    /// Streams Claude's reply to `transcript`. Cancel by dropping the stream (or cancelling the consuming task).
    /// `conversation` is replayed unchanged ahead of the new user turn; its pinned model, settings and tool
    /// definitions, if any, win over `model`, `settings` and `tools`, so a conversation never changes model, thinking,
    /// effort or its tools.
    public func respond(to transcript: String, conversation: ClaudeConversation = ClaudeConversation(),
                        context: ClaudeTurnContext, settings: RouteSettings, model: ClaudeModel = .chosen,
                        tools: [ToolDefinition] = []) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let message: JSONValue = [
            "role": "user",
            "content": [
                ["type": "text", "text": .string(AssistantPrompt.contextNote(context))],
                ["type": "text", "text": .string(transcript)],
            ],
        ]
        return stream(conversation: conversation, userMessage: message, settings: conversation.settings ?? settings,
                      model: conversation.model ?? model, tools: tools)
    }

    /// The next request of a turn whose last completion stopped for tool use: `conversation` is that completion's
    /// conversation followed by the user message carrying the tool results (`appendToolResults`). Same settings and
    /// tools as before.
    func continueAfterTools(_ conversation: ClaudeConversation, settings: RouteSettings) -> AsyncThrowingStream<ClaudeEvent, Error> {
        stream(conversation: conversation, userMessage: nil, settings: conversation.settings ?? settings,
               model: conversation.model ?? .chosen, tools: [])
    }

    private func stream(conversation: ClaudeConversation, userMessage: JSONValue?, settings: RouteSettings,
                        model: ClaudeModel, tools: [ToolDefinition]) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let timedOut = Flag()
            let work = Task {
                do {
                    try await self.run(conversation: conversation, userMessage: userMessage, settings: settings,
                                       model: model, tools: tools) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    let mapped = timedOut.value ? ClaudeError.timedOut : Self.map(error)
                    if mapped != .cancelled { AssistantLog.add("Claude failed: \(mapped.logKind)") }
                    continuation.finish(throwing: mapped)
                }
            }
            let deadline = Task { [deadline = configuration.deadline] in
                try await Task.sleep(for: .seconds(deadline))
                timedOut.value = true
                work.cancel()
            }
            continuation.onTermination = { _ in
                work.cancel()
                deadline.cancel()
            }
        }
    }

    /// Opens the TLS connection ahead of a request (at a wake word), at most every 45 s. Costs nothing.
    public func warmUp() {
        let now = Date()
        let due: Bool = warmLock.withLock {
            if let lastWarm, now.timeIntervalSince(lastWarm) < 45 { return false }
            lastWarm = now
            return true
        }
        guard due, let key = try? keyProvider() else { return }
        var request = URLRequest(url: modelURL(configuration.model))
        apply(key: key, to: &request)
        Task.detached(priority: .utility) { [session] in
            _ = try? await session.data(for: request)
        }
    }

    /// The Keys screen's Test: reads the chosen model's details (no tokens, no cost).
    public func testKey(_ key: String, model: ClaudeModel = .chosen) async -> KeyTestResult {
        var request = URLRequest(url: modelURL(model.rawValue))
        request.timeoutInterval = 15
        apply(key: KeyStore.clean(key), to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            AssistantLog.add("Anthropic key test: HTTP \(status)")
            switch status {
            case 200:
                let json = try? JSONValue.parse(data)
                let search = json?["capabilities"]?["server_tools"]?["web_search"]?["supported"]?.bool
                if let search { AssistantLog.add("Models API: web search supported \(search)") }
                return .works(search == false ? "Works. \(model.displayName) is available, but web search isn't."
                                              : "Works. \(model.displayName) is ready.")
            case 401: return .failed("Anthropic didn't accept this key.")
            case 403: return .failed("This key isn't allowed to use Claude.")
            case 404: return .failed("\(model.displayName) isn't available to this account.")
            case 429: return .failed("Anthropic is rate-limiting this key. Try again in a minute.")
            default: return .failed("Anthropic answered with an error (\(status)). Try again later.")
            }
        } catch {
            let mapped = Self.map(error)
            AssistantLog.add("Anthropic key test failed: \(mapped.logKind)")
            return .failed(mapped == .offline ? "Your iPhone is offline." : "ReGlass couldn't reach Anthropic.")
        }
    }

    // MARK: The reply loop

    private func run(conversation previous: ClaudeConversation, userMessage: JSONValue?, settings: RouteSettings,
                     model: ClaudeModel, tools: [ToolDefinition],
                     emit: @escaping (ClaudeEvent) -> Void) async throws {
        let key: String
        do {
            guard let saved = try keyProvider() else { throw ClaudeError.noKey }
            key = saved
        } catch KeyStoreError.locked {
            throw ClaudeError.keyLocked
        }

        // Append-only: earlier messages exactly as they went over the wire, then this turn's user message (context
        // note and transcript, or nothing when continuing after tool results), kept as sent for every request of the
        // turn and any later replay. The first request pins the model, the settings and the tool definitions.
        var conversation = previous
        conversation.pin(model: model)
        conversation.pin(settings)
        conversation.pinTools(clientTools.render(tools))
        if let userMessage { conversation.append(userMessage) }

        let watch = Stopwatch()
        let output = OutputTracker(watch: watch, emit: emit)
        var usage = ClaudeUsage()
        var continuations = 0
        while true {
            let attempt = try await streamWithRetries(conversation: &conversation, settings: settings, model: model,
                                                      key: key, output: output)
            usage.add(attempt.usage)
            if let switched = attempt.content.last(where: { $0["type"]?.string == "fallback" }) {
                // Model ids only: log-safe.
                let from = switched["from"]?["model"]?.string ?? model.rawValue
                let to = switched["to"]?["model"]?.string ?? "another model"
                AssistantLog.add("Claude: \(from) declined; \(to) answered (Anthropic's server-side fallback)")
            }
            // Every response is kept as received, in its own assistant message, so what's replayed later is exactly
            // what the server saw (thinking blocks with their signatures, even empty ones; tool calls; citations).
            if !attempt.content.isEmpty {
                conversation.append(["role": "assistant", "content": .array(attempt.content)])
            }
            if attempt.stopReason == "pause_turn", continuations < 4, !attempt.content.isEmpty {
                // The server paused its own loop (long search turn): send the paused content back unchanged.
                continuations += 1
                AssistantLog.add("Claude paused its turn; continuing (\(continuations))")
                continue
            }
            let stop: ClaudeCompletion.Stop
            switch attempt.stopReason {
            case "end_turn", "stop_sequence": stop = .endTurn
            case "tool_use" where !attempt.toolCalls.isEmpty: stop = .toolUse(attempt.toolCalls)
            case "max_tokens": stop = .maxTokens
            case "refusal": stop = .refusal(category: attempt.refusalCategory)
            default: stop = .other(attempt.stopReason ?? "none")
            }
            let completion = ClaudeCompletion(stop: stop, usage: usage, firstTextAfter: output.firstTextAfter,
                                              duration: watch.elapsed, conversation: conversation)
            let calls = attempt.toolCalls.isEmpty ? "" : ", \(attempt.toolCalls.count) tool call\(attempt.toolCalls.count == 1 ? "" : "s")"
            AssistantLog.add("Claude done (\(attempt.stopReason ?? "no stop reason")\(calls), \(model.shortName), "
                             + "\(settings.logDescription)) in "
                             + "\(completion.duration.seconds), first text after "
                             + "\(completion.firstTextAfter?.seconds ?? "—"); \(usage.logDescription)")
            emit(.completed(completion))
            return
        }
    }

    /// One request, retried by error class while this request has streamed nothing. Also settles which web search and
    /// web fetch tool versions this account accepts, and falls back when the API turns the client tools' definitions
    /// down.
    private func streamWithRetries(conversation: inout ClaudeConversation, settings: RouteSettings, model: ClaudeModel,
                                   key: String, output: OutputTracker) async throws -> StreamResult {
        var attempt = 0
        let mark = output.count
        while true {
            try Task.checkCancellation()
            if !conversation.searchPinned { conversation.pinSearch(PinnedSearch(searchTool.current)) }
            if !conversation.fetchPinned { conversation.pinFetch(PinnedFetch(fetchTool.current)) }
            let search = conversation.search
            let fetch = conversation.fetch
            let definitions = conversation.toolDefinitions ?? []
            let fallback = model.hasServerFallback && serverFallback.enabled
            let body = try self.body(messages: conversation.messages, model: model, settings: settings, search: search,
                                     fetch: fetch, clientTools: definitions, fallback: fallback)
            do {
                let result = try await streamOnce(body: body, key: key, fallback: fallback, output: output)
                if let search { searchTool.accepted(search.tool) }
                if let fetch { fetchTool.accepted(fetch.tool) }
                return result
            } catch let failure as Failure {
                if case .http(400, _, let message, _) = failure, fallback, message.lowercased().contains("fallback") {
                    // The server-side fallback turned down (not offered to this account): answer without it.
                    serverFallback.reject()
                    continue
                }
                if case .http(400, _, let message, _) = failure {
                    // Definitions the API won't take: strict mode first, then the web fetch or web search version,
                    // then (for a conversation that hasn't used one) the iPhone tools.
                    let lowered = message.lowercased()
                    let namesFetch = lowered.contains("web_fetch") || lowered.contains("web fetch")
                        || lowered.contains("max_content_tokens")
                    let namesSearch = lowered.contains("web_search") || lowered.contains("web search")
                        || lowered.contains("user_location")
                    // `allowed_callers` without a tool's name: the one that sends it (search first, as before fetch).
                    let callers = lowered.contains("allowed_callers") && !namesFetch && !namesSearch
                    let aboutFetch = namesFetch
                        || (callers && fetch?.tool.direct == true && search?.tool.direct != true)
                    let aboutSearch = namesSearch || (callers && !aboutFetch)
                    if !aboutSearch, !aboutFetch, let retry = clientTools.reject(definitions, message: message,
                                                                    conversationUsedTools: conversation.hasClientToolUse) {
                        conversation.pinTools(retry, replacing: true)
                        continue
                    }
                    if aboutFetch, let fetch, fetchTool.reject(fetch.tool, message: message) {
                        conversation.pinFetch(PinnedFetch(fetchTool.current), replacing: true)
                        continue
                    }
                    if !aboutFetch, let search,
                       searchTool.reject(search.tool, message: message, alone: definitions.isEmpty && fetch == nil) {
                        conversation.pinSearch(PinnedSearch(searchTool.current), replacing: true)
                        continue
                    }
                }
                guard failure.isRetryable, output.count == mark, attempt < 2 else { throw failure.claudeError }
                attempt += 1
                let wait = failure.retryAfter.map { min($0, 4) } ?? (attempt == 1 ? 0.6 : 1.5)
                AssistantLog.add("Claude \(failure.claudeError.logKind); retrying in \(String(format: "%.1f", wait)) s")
                try await Task.sleep(for: .seconds(wait))
            } catch let urlError as URLError where urlError.code != .cancelled {
                let mapped = Self.map(urlError)
                let retryable = mapped != .offline || attempt == 0
                guard retryable, output.count == mark, attempt < 2 else { throw mapped }
                attempt += 1
                AssistantLog.add("Claude \(mapped.logKind); retrying")
                try await Task.sleep(for: .seconds(attempt == 1 ? 0.5 : 1.2))
            }
        }
    }

    private func streamOnce(body: Data, key: String, fallback: Bool,
                            output: OutputTracker) async throws -> StreamResult {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = configuration.idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if fallback { request.setValue(ServerFallbackChoice.beta, forHTTPHeaderField: "anthropic-beta") }
        apply(key: key, to: &request)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.stream("no_response") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 32_768 { break }
            }
            let json = try? JSONValue.parse(data)
            let type = json?["error"]?["type"]?.string ?? "unknown"
            let message = json?["error"]?["message"]?.string ?? ""
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            AssistantLog.add("Claude HTTP \(http.statusCode) \(type)")
            throw Failure.http(http.statusCode, type, message, retryAfter)
        }

        var stream = StreamAccumulator()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).drop(while: { $0 == " " })
            guard !payload.isEmpty else { continue }
            let event: JSONValue
            do {
                event = try JSONValue.parse(String(payload))
            } catch {
                throw Failure.stream("unreadable_event")
            }
            for item in try stream.handle(event) { output.emit(item) }
            if stream.finished { break }
        }
        guard stream.finished else { throw Failure.stream("ended_early") }
        return stream.result
    }

    // MARK: Request

    private func body(messages: [JSONValue], model: ClaudeModel, settings: RouteSettings, search: PinnedSearch?,
                      fetch: PinnedFetch?, clientTools: [JSONValue], fallback: Bool) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": .int(configuration.maxTokens),
            "stream": true,
            "output_config": ["effort": .string(settings.effort.rawValue)],
            "system": [
                ["type": "text", "text": .string(AssistantPrompt.system), "cache_control": ["type": "ephemeral"]],
            ],
            "messages": .array(messages),
        ]
        if let thinking = model.thinking(settings.thinking) { body["thinking"] = thinking }
        if fallback { body["fallbacks"] = "default" }
        // Web search, web fetch, then the iPhone tools as pinned (sorted by name): the same tools give the same bytes.
        var tools: [JSONValue] = []
        if let search {
            let tool = search.tool
            var definition: [String: JSONValue] = [
                "type": .string(tool.type),
                "name": "web_search",
                "max_uses": .int(configuration.maxSearches),
            ]
            if tool.direct { definition["allowed_callers"] = ["direct"] }
            if tool.localized {
                definition["user_location"] = ["type": "approximate", "timezone": .string(search.timeZone)]
            }
            tools.append(.object(definition))
        }
        if let fetch {
            // Pages whose address is in the conversation (a news story's sources, a search result), cut to about
            // 12,000 tokens; no citations (the answer is spoken).
            var definition: [String: JSONValue] = [
                "type": .string(fetch.tool.type),
                "name": "web_fetch",
                "max_uses": .int(configuration.maxFetches),
                "max_content_tokens": .int(configuration.maxFetchTokens),
            ]
            if fetch.tool.direct { definition["allowed_callers"] = ["direct"] }
            tools.append(.object(definition))
        }
        tools += clientTools
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return try JSONValue.object(body).encoded()
    }

    private func modelURL(_ model: String) -> URL {
        configuration.baseURL.appendingPathComponent("v1/models/\(model)")
    }

    func apply(key: String, to request: inout URLRequest) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    // MARK: Errors

    static func map(_ error: Error) -> ClaudeError {
        switch error {
        case let error as ClaudeError: return error
        case let failure as Failure: return failure.claudeError
        case is CancellationError: return .cancelled
        case KeyStoreError.locked: return .keyLocked
        case let error as URLError:
            switch error.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .timedOut: return .timedOut
            default: return .network(error.code.rawValue)
            }
        default: return .streamBroken
        }
    }
}

// MARK: - Failures

private enum Failure: Error {
    case http(Int, String, String, TimeInterval?)
    case stream(String)
    /// The stream delivered an `error` event (e.g. overloaded_error mid-stream).
    case streamError(String)

    var isRetryable: Bool {
        switch self {
        case .http(let status, _, _, _): return status == 429 || status >= 500
        case .stream: return true
        case .streamError(let type): return type == "overloaded_error" || type == "api_error" || type == "rate_limit_error"
        }
    }

    var retryAfter: TimeInterval? {
        if case .http(_, _, _, let retryAfter) = self { return retryAfter }
        return nil
    }

    var claudeError: ClaudeError {
        switch self {
        case .http(let status, let type, let message, _):
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
        case .stream: return .streamBroken
        case .streamError(let type):
            switch type {
            case "overloaded_error": return .overloaded
            case "rate_limit_error": return .rateLimited
            default: return .serverError(500)
            }
        }
    }
}

/// A thread-safe boolean.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Forwards events and counts them: a request that has emitted anything may not be retried (it would repeat what was
/// already spoken or recorded).
private final class OutputTracker: @unchecked Sendable {
    private let watch: Stopwatch
    private let forward: (ClaudeEvent) -> Void
    private(set) var count = 0
    private(set) var firstTextAfter: TimeInterval?

    init(watch: Stopwatch, emit: @escaping (ClaudeEvent) -> Void) {
        self.watch = watch
        self.forward = emit
    }

    func emit(_ event: ClaudeEvent) {
        count += 1
        if case .text = event, firstTextAfter == nil { firstTextAfter = watch.elapsed }
        forward(event)
    }
}

// MARK: - Server-side fallback

/// Whether requests carry Anthropic's server-side fallback (`fallbacks: "default"` under the beta header), on the
/// models that have one (`ClaudeModel.hasServerFallback`). On by default; a 400 naming it turns it off until the next
/// launch, and replies go without it.
final class ServerFallbackChoice: @unchecked Sendable {
    static let beta = "server-side-fallback-2026-07-01"

    private let lock = NSLock()
    private var off = false

    var enabled: Bool { lock.withLock { !off } }

    func reject() {
        let first: Bool = lock.withLock {
            defer { off = true }
            return !off
        }
        if first { AssistantLog.add("Claude: the API turned down the server-side fallback; answering without it") }
    }
}

// MARK: - Web search tool version

/// Which web search tool definition the account accepts. The user asked for `web_search_20250305` (`max_uses` 3),
/// which every model takes; if the API rejects it, the newer versions follow with `allowed_callers: ["direct"]`
/// (no dynamic filtering). The first one that works is remembered across launches, and the log says which.
/// The web search tool a conversation was started with, pinned in `ClaudeConversation` so every request in it sends
/// the same bytes (the time zone hint included).
struct PinnedSearch: Sendable, Equatable {
    let tool: WebSearchToolChoice.Tool
    let timeZone: String

    init?(_ tool: WebSearchToolChoice.Tool?, timeZone: TimeZone = .current) {
        guard let tool else { return nil }
        self.tool = tool
        self.timeZone = timeZone.identifier
    }
}

final class WebSearchToolChoice: @unchecked Sendable {
    struct Tool: Equatable, Sendable {
        let type: String
        /// `allowed_callers: ["direct"]`.
        let direct: Bool
        /// `user_location` with the iPhone's time zone.
        let localized: Bool
    }

    static let ladder: [(type: String, direct: Bool)] = [
        ("web_search_20250305", false),
        ("web_search_20260209", true),
        ("web_search_20260318", true),
    ]

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private static let indexKey = "reglass.assistant.webSearchToolIndex"
    private static let localizedKey = "reglass.assistant.webSearchLocalized"
    private var index: Int
    private var localized: Bool

    init() {
        let saved = defaults.object(forKey: Self.indexKey) as? Int ?? 0
        // Every version turned down last time: try again from the top at each launch rather than never searching.
        index = saved < Self.ladder.count ? saved : 0
        localized = defaults.object(forKey: Self.localizedKey) as? Bool ?? true
        if index > 0 { AssistantLog.add("Web search: using \(Self.ladder[index].type)") }
    }

    /// Nil once every version has been turned down: replies then go without web search.
    var current: Tool? {
        lock.withLock {
            guard index < Self.ladder.count else { return nil }
            let entry = Self.ladder[index]
            return Tool(type: entry.type, direct: entry.direct, localized: localized)
        }
    }

    private var confirmed = false

    /// The API took a request carrying `tool`: say once per launch which version works.
    func accepted(_ tool: Tool) {
        let first: Bool = lock.withLock {
            defer { confirmed = true }
            return !confirmed
        }
        if first { AssistantLog.add("Web search: \(tool.type) accepted\(tool.direct ? " (direct callers)" : "")") }
    }

    /// A 400 for a request carrying `tool`. Returns true when there's something else to try. `alone`: web search was
    /// the request's only tool, so a message that just says "tool" is about it (with iPhone tools too, it must name it).
    func reject(_ tool: Tool, message: String, alone: Bool) -> Bool {
        let lowered = message.lowercased()
        return lock.withLock {
            guard index < Self.ladder.count, Self.ladder[index].type == tool.type else { return true }  // already moved on
            if localized, lowered.contains("user_location") || lowered.contains("timezone") || lowered.contains("country") {
                localized = false
                defaults.set(false, forKey: Self.localizedKey)
                AssistantLog.add("Web search: the API turned down the time zone hint; searching without it")
                return true
            }
            guard lowered.contains("web_search") || (alone && lowered.contains("tool"))
                    || lowered.contains("allowed_callers") else {
                return false
            }
            index += 1
            defaults.set(index, forKey: Self.indexKey)
            if index < Self.ladder.count {
                AssistantLog.add("Web search: \(tool.type) was turned down; trying \(Self.ladder[index].type)")
            } else {
                AssistantLog.add("Web search: every tool version was turned down; answering without web search")
            }
            return true
        }
    }
}

// MARK: - Web fetch tool version

/// The web fetch tool a conversation was started with, pinned in `ClaudeConversation` like `PinnedSearch`, so every
/// request in it sends the same bytes.
struct PinnedFetch: Sendable, Equatable {
    let tool: WebFetchToolChoice.Tool

    init?(_ tool: WebFetchToolChoice.Tool?) {
        guard let tool else { return nil }
        self.tool = tool
    }
}

/// Which web fetch tool definition the account accepts, settled like `WebSearchToolChoice`: `web_fetch_20250910` first
/// (the basic version, which the docs list for Haiku 5.5), then `web_fetch_20260209` with `allowed_callers: ["direct"]`
/// (its dynamic filtering is documented for Opus and Sonnet only, and needs code execution). `max_uses` 3 and
/// `max_content_tokens` 12,000 either way (`ClaudeConfiguration`). The first one that works is remembered across
/// launches; with every version turned down, replies go without web fetch until the next launch tries again.
final class WebFetchToolChoice: @unchecked Sendable {
    struct Tool: Equatable, Sendable {
        let type: String
        /// `allowed_callers: ["direct"]`.
        let direct: Bool
    }

    static let ladder: [(type: String, direct: Bool)] = [
        ("web_fetch_20250910", false),
        ("web_fetch_20260209", true),
    ]

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private static let indexKey = "reglass.assistant.webFetchToolIndex"
    private var index: Int
    private var confirmed = false

    init() {
        let saved = defaults.object(forKey: Self.indexKey) as? Int ?? 0
        index = saved < Self.ladder.count ? saved : 0
        if index > 0 { AssistantLog.add("Web fetch: using \(Self.ladder[index].type)") }
    }

    /// Nil once every version has been turned down.
    var current: Tool? {
        lock.withLock {
            guard index < Self.ladder.count else { return nil }
            let entry = Self.ladder[index]
            return Tool(type: entry.type, direct: entry.direct)
        }
    }

    /// The API took a request carrying `tool`: say once per launch which version works.
    func accepted(_ tool: Tool) {
        let first: Bool = lock.withLock {
            defer { confirmed = true }
            return !confirmed
        }
        if first { AssistantLog.add("Web fetch: \(tool.type) accepted\(tool.direct ? " (direct callers)" : "")") }
    }

    /// A 400 about web fetch for a request carrying `tool`. Returns true when there's something else to try (the next
    /// version, or none at all).
    func reject(_ tool: Tool, message: String) -> Bool {
        lock.withLock {
            guard index < Self.ladder.count, Self.ladder[index].type == tool.type else { return true }  // already moved on
            index += 1
            defaults.set(index, forKey: Self.indexKey)
            if index < Self.ladder.count {
                AssistantLog.add("Web fetch: \(tool.type) was turned down; trying \(Self.ladder[index].type)")
            } else {
                AssistantLog.add("Web fetch: every tool version was turned down; answering without web fetch")
            }
            return true
        }
    }
}

// MARK: - Streaming

private struct StreamResult {
    var stopReason: String?
    var refusalCategory: String?
    var usage = ClaudeUsage()
    /// The assistant content blocks, rebuilt exactly enough to send back (after `pause_turn`, with tool results, and
    /// in any later replay).
    var content: [JSONValue] = []
    /// The client tool calls (`tool_use` blocks), in content order.
    var toolCalls: [ClaudeToolCall] = []
}

/// Rebuilds the message from its server-sent events and turns them into `ClaudeEvent`s.
private struct StreamAccumulator {
    private struct Block {
        var start: [String: JSONValue]
        var type: String
        var text = ""
        var thinking = ""
        var signature = ""
        var inputJSON = ""
        var citations: [JSONValue] = []
    }

    private var blocks: [Int: Block] = [:]
    private(set) var finished = false
    private var stopReason: String?
    private var refusalCategory: String?
    private var usage = ClaudeUsage()

    mutating func handle(_ event: JSONValue) throws -> [ClaudeEvent] {
        guard let type = event["type"]?.string else { return [] }
        switch type {
        case "message_start":
            let messageUsage = event["message"]?["usage"]
            usage.inputTokens = messageUsage?["input_tokens"]?.int ?? 0
            usage.cacheReadTokens = messageUsage?["cache_read_input_tokens"]?.int ?? 0
            usage.cacheWriteTokens = messageUsage?["cache_creation_input_tokens"]?.int ?? 0
            usage.outputTokens = messageUsage?["output_tokens"]?.int ?? 0
            return []

        case "content_block_start":
            guard let index = event["index"]?.int, let start = event["content_block"]?.object,
                  let blockType = start["type"]?.string else { return [] }
            var block = Block(start: start, type: blockType)
            block.text = start["text"]?.string ?? ""
            block.thinking = start["thinking"]?.string ?? ""
            block.signature = start["signature"]?.string ?? ""
            block.citations = start["citations"]?.array ?? []
            blocks[index] = block
            if blockType == "web_search_tool_result" {
                let id = start["tool_use_id"]?.string ?? ""
                if let results = start["content"]?.array {
                    return [.searchFinished(id: id, resultCount: results.count)]
                }
                let code = start["content"]?["error_code"]?.string ?? "unknown"
                return [.searchFailed(id: id, code: code)]
            }
            if blockType == "web_fetch_tool_result" {
                // Arrives whole in this one event; kept as received for the replay (`result`'s default case).
                let id = start["tool_use_id"]?.string ?? ""
                let content = start["content"]
                if content?["type"]?.string == "web_fetch_tool_result_error" {
                    return [.fetchFailed(id: id, code: content?["error_code"]?.string ?? "unknown")]
                }
                return [.fetchFinished(id: id, url: content?["url"]?.string ?? "")]
            }
            if blockType == "text", !block.text.isEmpty {
                return [.text(block.text)]
            }
            return []

        case "content_block_delta":
            guard let index = event["index"]?.int, var block = blocks[index], let delta = event["delta"] else { return [] }
            var out: [ClaudeEvent] = []
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                block.text += text
                if !text.isEmpty { out.append(.text(text)) }
            case "thinking_delta":
                block.thinking += delta["thinking"]?.string ?? ""
            case "signature_delta":
                block.signature += delta["signature"]?.string ?? ""
            case "input_json_delta":
                block.inputJSON += delta["partial_json"]?.string ?? ""
            case "citations_delta":
                if let citation = delta["citation"] { block.citations.append(citation) }
            default:
                break
            }
            blocks[index] = block
            return out

        case "content_block_stop":
            guard let index = event["index"]?.int, let block = blocks[index] else { return [] }
            if block.type == "server_tool_use", block.start["name"]?.string == "web_search" {
                let input = (try? JSONValue.parse(block.inputJSON.isEmpty ? "{}" : block.inputJSON)) ?? block.start["input"]
                let query = input?["query"]?.string ?? ""
                return [.searchStarted(id: block.start["id"]?.string ?? "", query: query)]
            }
            if block.type == "server_tool_use", block.start["name"]?.string == "web_fetch" {
                let input = (try? JSONValue.parse(block.inputJSON.isEmpty ? "{}" : block.inputJSON)) ?? block.start["input"]
                return [.fetchStarted(id: block.start["id"]?.string ?? "", url: input?["url"]?.string ?? "")]
            }
            return []

        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let category = event["delta"]?["stop_details"]?["category"]?.string { refusalCategory = category }
            if let category = event["stop_details"]?["category"]?.string { refusalCategory = category }
            if let deltaUsage = event["usage"] {
                if let output = deltaUsage["output_tokens"]?.int { usage.outputTokens = output }
                if let input = deltaUsage["input_tokens"]?.int, input > 0 { usage.inputTokens = input }
                if let searches = deltaUsage["server_tool_use"]?["web_search_requests"]?.int { usage.webSearches = searches }
                if let fetches = deltaUsage["server_tool_use"]?["web_fetch_requests"]?.int { usage.webFetches = fetches }
            }
            return []

        case "message_stop":
            finished = true
            return []

        case "error":
            throw Failure.streamError(event["error"]?["type"]?.string ?? "unknown")

        default:   // ping, and anything newer
            return []
        }
    }

    /// After a server-side fallback, the declined model's part of the message comes before the last `fallback` block.
    /// Of that part only text and web searches or page reads with their results are sent back (and the `fallback`
    /// block where it was): its thinking blocks, tool calls and anything else are left out, as the API requires, and
    /// its tool calls aren't run.
    var result: StreamResult {
        var result = StreamResult(stopReason: stopReason, refusalCategory: refusalCategory, usage: usage)
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        let boundary = ordered.lastIndex { $0.type == "fallback" } ?? 0
        let answered = Set(ordered.compactMap { block -> String? in
            ["web_search_tool_result", "web_fetch_tool_result"].contains(block.type)
                ? block.start["tool_use_id"]?.string : nil
        })
        result.content = ordered.enumerated().compactMap { position, block in
            if position < boundary {
                switch block.type {
                case "text", "web_search_tool_result", "web_fetch_tool_result": break
                case "server_tool_use" where answered.contains(block.start["id"]?.string ?? ""): break
                default: return nil
                }
            }
            var object = block.start
            switch block.type {
            case "text":
                // Keys as the server sent them; only the streamed parts are filled in.
                object["text"] = .string(block.text)
                if !block.citations.isEmpty { object["citations"] = .array(block.citations) }
            case "thinking":
                // Kept even when the text is empty (Haiku 5.5 omits thinking text by default; the signature counts).
                object["thinking"] = .string(block.thinking)
                object["signature"] = .string(block.signature)
            case "server_tool_use":
                if let input = try? JSONValue.parse(block.inputJSON.isEmpty ? "{}" : block.inputJSON) {
                    object["input"] = input
                }
            case "tool_use":
                // The arguments arrive as `input_json_delta` fragments (buffered and validated by the server, as
                // `eager_input_streaming` is off). Empty means no arguments.
                let raw = block.inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = raw.isEmpty ? JSONValue.object([:]) : (try? JSONValue.parse(raw))
                if let parsed { object["input"] = parsed }
                result.toolCalls.append(ClaudeToolCall(id: block.start["id"]?.string ?? "",
                                                       name: block.start["name"]?.string ?? "",
                                                       input: parsed ?? (block.start["input"] ?? .object([:])),
                                                       unreadableInput: parsed == nil ? raw : nil))
            default:
                break
            }
            return .object(object)
        }
        return result
    }
}
