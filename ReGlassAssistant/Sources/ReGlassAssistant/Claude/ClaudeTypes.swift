import Foundation

/// Fixed settings for ReGlass's Claude calls.
public struct ClaudeConfiguration: Sendable {
    /// For small jobs beside the answers (`quickAnswer`) and the interpreter. The answers use the model the owner
    /// chose (`ClaudeModel.chosen`), pinned per conversation.
    public var model = ClaudeModel.haiku.rawValue
    /// API version 2026-10-21: no sampling parameters may be sent (none are).
    public var apiVersion = "2026-10-21"
    /// Thinking counts toward this, so it is far above a spoken reply's length.
    public var maxTokens = 8192
    /// Web searches per request.
    public var maxSearches = 3
    /// Pages read with web fetch per request.
    public var maxFetches = 3
    /// A fetched page's text is cut to about this many tokens.
    public var maxFetchTokens = 12_000
    /// A whole reply, searches included, must finish within this.
    public var deadline: TimeInterval = 75
    /// Gives up on a request whose stream goes quiet for this long.
    public var idleTimeout: TimeInterval = 30
    public var baseURL = URL(string: "https://api.anthropic.com")!

    public init() {}
}

/// What changes from turn to turn. It goes into the user turn, never the system prompt, so the system prompt and
/// tools stay byte-identical and cacheable.
public struct ClaudeTurnContext: Sendable {
    public enum Surface: Sendable, Equatable {
        /// Spoken through the glasses.
        case glasses
        /// Typed in Talk to ReGlass; the reply is still spoken.
        case typed
        /// Typed in Chats (a new chat or a reply), where the answer shows as text; `readAloud` when it's also spoken
        /// (only into the glasses or headphones).
        case chat(readAloud: Bool)
        /// Typed in the bar on the Reminders page; the answer shows there as one line of text, never spoken.
        case reminders
    }

    public var date: Date
    public var timeZone: TimeZone
    public var surface: Surface
    /// Every category notes, reminders and list items can go in, in order ("Shopping", "To-do", …). Empty: none said.
    public var categories: [String]
    /// The category open on screen where the owner typed (a chip selected on the Reminders page), so a bare line
    /// like "eggs and two lemons" goes on that list. Nil: none.
    public var openCategory: String?
    /// Short sentences from ReGlass about what's going on right now ("A reminder went off 3 minutes ago: check on the
    /// food."), each ending with a full stop, added at the end of the context note. Built in one place in the app
    /// (`AssistantController.turnContext`).
    public var extras: [String]

    public init(date: Date = Date(), timeZone: TimeZone = .current, surface: Surface, categories: [String] = [],
                openCategory: String? = nil, extras: [String] = []) {
        self.date = date
        self.timeZone = timeZone
        self.surface = surface
        self.categories = categories
        self.openCategory = openCategory
        self.extras = extras
    }
}

/// A conversation with Claude exactly as it went over the wire: every message as sent (the user turn with its
/// context note) and every assistant message as received (thinking blocks with their signatures, `server_tool_use`,
/// `web_search_tool_result`, `web_fetch_tool_result`, citations), in order. Strictly append-only and replayed
/// byte-for-byte, which the models' preserved-thinking check requires (edited history invalidates thinking blocks,
/// a 400 on newer accounts) and which keeps the prompt cache's prefix matching. Never rebuild it from the chat store.
///
/// A new conversation starts empty. Follow-ups reuse the previous turn's `TurnOutcome.conversation`.
/// The first turn pins the model, effort and thinking settings. The thinking blocks and prompt cache belong
/// to that model.
///
/// The iPhone tools' definitions are pinned the same way, as first sent: `tools` sits at the very front of the prompt,
/// and the model rejects a replayed thinking block once anything before it changed. A connector switched on or off
/// mid-conversation therefore takes effect from the next conversation; a pinned tool that's gone answers with a failure.
public struct ClaudeConversation: Sendable, Equatable {
    public private(set) var messages: [JSONValue] = []
    /// The model, fixed by the conversation's first request.
    public private(set) var model: ClaudeModel?
    /// Thinking and effort, fixed by the conversation's first request.
    public private(set) var settings: RouteSettings?
    /// The client tools' definitions exactly as the first request sent them (web search excluded), sorted by name.
    private(set) var toolDefinitions: [JSONValue]?
    /// The web search tool as the first request sent it (its version and the time zone it named), fixed for the same
    /// reason. `searchPinned` with a nil `search`: the conversation started without web search.
    private(set) var search: PinnedSearch?
    private(set) var searchPinned = false
    /// The web fetch tool as the first request sent it, pinned the same way. `fetchPinned` with a nil `fetch`: the
    /// conversation started without web fetch.
    private(set) var fetch: PinnedFetch?
    private(set) var fetchPinned = false

    public init() {}

    public var isEmpty: Bool { messages.isEmpty }

    mutating func append(_ message: JSONValue) {
        messages.append(message)
    }

    mutating func pin(_ settings: RouteSettings) {
        if self.settings == nil { self.settings = settings }
    }

    mutating func pin(model: ClaudeModel) {
        if self.model == nil { self.model = model }
    }

    /// Pins the tool definitions on the first request; later calls change nothing unless `replacing` (the API turned
    /// the definitions down before any of them was used).
    mutating func pinTools(_ definitions: [JSONValue], replacing: Bool = false) {
        if toolDefinitions == nil || replacing { toolDefinitions = definitions }
    }

    /// Pins the web search tool on the first request; later calls change nothing unless `replacing` (the API turned
    /// that version down).
    mutating func pinSearch(_ search: PinnedSearch?, replacing: Bool = false) {
        guard !searchPinned || replacing else { return }
        self.search = search
        searchPinned = true
    }

    /// Pins the web fetch tool on the first request; later calls change nothing unless `replacing` (the API turned
    /// that version down).
    mutating func pinFetch(_ fetch: PinnedFetch?, replacing: Bool = false) {
        guard !fetchPinned || replacing else { return }
        self.fetch = fetch
        fetchPinned = true
    }

    /// The last message is Claude's with tool calls nobody answered (it stopped at `max_tokens` or a refusal right
    /// after them): not something a follow-up can continue.
    var endsWithUnansweredToolUse: Bool {
        guard let last = messages.last, last["role"]?.string == "assistant" else { return false }
        return (last["content"]?.array ?? []).contains { $0["type"]?.string == "tool_use" }
    }

    /// Claude has called a client tool in this conversation: its definitions must stay in every later request.
    var hasClientToolUse: Bool {
        messages.contains { message in
            message["role"]?.string == "assistant"
                && (message["content"]?.array ?? []).contains { $0["type"]?.string == "tool_use" }
        }
    }

    /// The user message answering one round of tool calls: one `tool_result` per call, in the calls' order.
    mutating func appendToolResults(_ results: [(call: ClaudeToolCall, result: ToolResult)]) {
        let blocks: [JSONValue] = results.map { item in
            var block: [String: JSONValue] = [
                "type": "tool_result",
                "tool_use_id": .string(item.call.id),
                "content": .string(item.result.content.isEmpty ? (item.result.isError ? "Failed." : "Done.")
                                                                : item.result.content),
            ]
            if item.result.isError { block["is_error"] = true }
            return .object(block)
        }
        append(["role": "user", "content": .array(blocks)])
    }

    /// Ends a tool round without another request, when the tools' own words were the answer
    /// (`ToolResult.spokenReply`): an assistant message with exactly those words, after the tool results. Append-only,
    /// so earlier thinking blocks stay valid, and a follow-up sees what was said.
    mutating func appendSpokenReply(_ text: String) {
        append(["role": "assistant", "content": [["type": "text", "text": .string(text)]]])
    }
}

/// One call Claude made to a client tool (a `tool_use` block).
public struct ClaudeToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Claude's arguments, parsed. An object when the stream delivered valid JSON.
    public let input: JSONValue
    /// The streamed arguments when they weren't valid JSON (the stream cut them off): the tool isn't run and Claude is
    /// told so.
    let unreadableInput: String?
}

/// What a reply stream delivers, in order.
public enum ClaudeEvent: Sendable {
    /// Visible reply text as it streams.
    case text(String)
    /// Claude started a web search. `query` is for the chat record and the screen only, never the log.
    case searchStarted(id: String, query: String)
    case searchFinished(id: String, resultCount: Int)
    /// The search didn't work; `code` is the API's error code (log-safe).
    case searchFailed(id: String, code: String)
    /// Claude started reading a web page. `url` is for the chat record and the screen only, never the log.
    case fetchStarted(id: String, url: String)
    case fetchFinished(id: String, url: String)
    /// The page couldn't be read; `code` is the API's error code (log-safe).
    case fetchFailed(id: String, code: String)
    /// The reply is complete.
    case completed(ClaudeCompletion)
}

public struct ClaudeUsage: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var webSearches = 0
    public var webFetches = 0

    public init() {}

    mutating func add(_ other: ClaudeUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        webSearches += other.webSearches
        webFetches += other.webFetches
    }

    var logDescription: String {
        "\(inputTokens) in, \(outputTokens) out, cache \(cacheReadTokens) read / \(cacheWriteTokens) written, \(webSearches) search\(webSearches == 1 ? "" : "es")"
            + (webFetches > 0 ? ", \(webFetches) page\(webFetches == 1 ? "" : "s") read" : "")
    }
}

public struct ClaudeCompletion: Sendable {
    public enum Stop: Sendable, Equatable {
        case endTurn
        /// Claude called client tools (`stop_reason: tool_use`): run them, append the results and continue.
        case toolUse([ClaudeToolCall])
        /// The reply hit `max_tokens`.
        case maxTokens
        /// Claude or a safety classifier declined. `category` is log-safe (e.g. "cyber"), often nil.
        case refusal(category: String?)
        case other(String)
    }

    public let stop: Stop
    public let usage: ClaudeUsage
    /// From the request to the first visible text.
    public let firstTextAfter: TimeInterval?
    public let duration: TimeInterval
    /// The conversation including this turn, exactly as sent and received: what a follow-up replays.
    public let conversation: ClaudeConversation
}

/// Why a reply failed, sorted by what can be done about it. Every case is log-safe.
public enum ClaudeError: Error, Sendable, Equatable {
    case noKey
    /// The Keychain won't hand the key over until the iPhone is unlocked once after a restart.
    case keyLocked
    case unauthorized
    case forbidden
    case billing
    case rateLimited
    case overloaded
    case serverError(Int)
    case badRequest(String)
    case modelNotFound
    case offline
    case network(Int)
    case timedOut
    /// The stream broke or couldn't be read.
    case streamBroken
    case cancelled

    /// For the log: a kind, never content.
    public var logKind: String {
        switch self {
        case .noKey: return "no key"
        case .keyLocked: return "key locked until first unlock"
        case .unauthorized: return "HTTP 401 authentication_error"
        case .forbidden: return "HTTP 403 permission_error"
        case .billing: return "HTTP 402 billing_error"
        case .rateLimited: return "HTTP 429 rate_limit_error"
        case .overloaded: return "overloaded_error"
        case .serverError(let status): return "HTTP \(status)"
        case .badRequest: return "HTTP 400 invalid_request_error"
        case .modelNotFound: return "HTTP 404 not_found_error"
        case .offline: return "offline"
        case .network(let code): return "network error \(code)"
        case .timedOut: return "timed out"
        case .streamBroken: return "stream broken"
        case .cancelled: return "cancelled"
        }
    }

    /// One plain sentence for the chat record and the screen.
    public var explanation: String {
        switch self {
        case .noKey: return "There's no Anthropic key yet. Add one in Settings → Keys."
        case .keyLocked: return "Unlock your iPhone once after a restart so ReGlass can read its keys."
        case .unauthorized: return "Anthropic didn't accept the key. Check it in Settings → Keys."
        case .forbidden: return "This Anthropic key isn't allowed to use the chosen Claude model."
        case .billing: return "Anthropic reported a billing problem with the account."
        case .rateLimited: return "Anthropic asked ReGlass to slow down. Try again in a moment."
        case .overloaded: return "Claude is busy right now. Try again in a moment."
        case .serverError: return "Anthropic had a problem answering. Try again in a moment."
        case .badRequest: return "Anthropic turned the request down."
        case .modelNotFound:
            return "The chosen Claude model isn't available to this Anthropic account. Choose another in Settings → Assistant → Model."
        case .offline: return "Your iPhone is offline."
        case .network: return "ReGlass couldn't reach Anthropic."
        case .timedOut: return "Claude took too long to answer."
        case .streamBroken: return "The answer was cut off."
        case .cancelled: return "Stopped."
        }
    }

    /// What ReGlass says aloud when it can't answer.
    public var spokenApology: String {
        switch self {
        case .noKey: return "I need an Anthropic key first. Add one in ReGlass, under Keys."
        case .keyLocked: return "Unlock your iPhone once, then ask me again."
        case .unauthorized, .forbidden: return "Anthropic didn't accept my key. Check it in ReGlass."
        case .billing: return "There's a billing problem with the Anthropic account."
        case .offline: return "Your phone seems to be offline, so I can't answer right now."
        case .network: return "Sorry, I couldn't reach Claude. Please try again."
        case .timedOut: return "Sorry, that took too long. Please try again."
        case .streamBroken: return "Sorry, I lost the answer. Please try again."
        default: return "Sorry, I can't answer right now. Please try again in a moment."
        }
    }
}

/// The outcome of a key's Test button.
public enum KeyTestResult: Sendable, Equatable {
    case works(String)
    case failed(String)
}
