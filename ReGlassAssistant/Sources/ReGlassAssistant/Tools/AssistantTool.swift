import Foundation

// Tools Claude can call that run on the iPhone ("client tools"): timers, reminders, music, weather, calendar, ...
// Each connector in the app supplies its tools; `TurnRunner` sends the enabled ones with every request, runs the
// calls Claude makes and hands the results back until Claude answers.
//
// Rules for every tool:
// - `run` never throws. A failure is `ToolResult.failure` with one plain sentence Claude can relay ("Reminders
//   access is off in Settings.").
// - Finish within a few seconds. Each call gets 10 s; after that Claude is told it took too long and the call's task
//   is cancelled. Honour Task cancellation (the wearer said a new wake word, the link dropped, or the time ran out).
// - Content (titles, names, notes) goes to Claude and to Chats only, never to the activity log.
// - Schemas: a tool whose schema uses only what strict mode accepts (types, properties, required, enum, const, anyOf,
//   items, description, plain formats; no minimum/maximum/minLength/maxLength/pattern) is sent with `strict: true`, so
//   Claude's arguments always match it. Strict mode doesn't guarantee the capitalisation of enum strings: compare
//   them case-insensitively. Keep optional parameters few (the limit is 24 across every strict tool in a request).

/// What Claude sees about a tool: its name, what it does and its input schema.
public struct ToolDefinition: Sendable, Equatable {
    /// `^[a-zA-Z0-9_-]{1,64}$`, unique across all connectors, e.g. `set_timer`.
    public let name: String
    /// For Claude: what the tool does, when to use it (and when not), what it returns. Several sentences is normal.
    public let description: String
    /// A JSON Schema object: `{"type": "object", "properties": {...}, "required": [...]}`.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A line for Chats (and the Talk to ReGlass screen) describing what a tool did: "Set a timer", "Food · 1 minute".
public struct ToolAction: Sendable, Equatable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

/// The outcome of one tool call.
public struct ToolResult: Sendable, Equatable {
    /// For Claude only: the facts it needs to answer, as short plain text or compact JSON. Not shown to the user.
    public var content: String
    public var isError: Bool
    /// What Chats shows for this call. Nil: the tool's name is shown.
    public var action: ToolAction?
    /// Words that are the answer itself, to be spoken as they are (a tool that answers in its own words, like the
    /// home's own assistant). When every call of a round brings one, the turn speaks them in the calls' order and ends
    /// there, without asking Claude again. Otherwise Claude gets `content` as usual, so `content` should carry the
    /// same words.
    public var spokenReply: String?

    public init(content: String, isError: Bool, action: ToolAction? = nil, spokenReply: String? = nil) {
        self.content = content
        self.isError = isError
        self.action = action
        self.spokenReply = spokenReply
    }

    public static func success(_ content: String, action: ToolAction? = nil, spokenReply: String? = nil) -> ToolResult {
        ToolResult(content: content, isError: false, action: action, spokenReply: spokenReply)
    }

    public static func failure(_ content: String, action: ToolAction? = nil, spokenReply: String? = nil) -> ToolResult {
        ToolResult(content: content, isError: true, action: action, spokenReply: spokenReply)
    }
}

/// When and where the request was made.
public struct ToolContext: Sendable {
    public var surface: ClaudeTurnContext.Surface
    public var date: Date
    public var timeZone: TimeZone

    public init(surface: ClaudeTurnContext.Surface, date: Date = Date(), timeZone: TimeZone = .current) {
        self.surface = surface
        self.date = date
        self.timeZone = timeZone
    }
}

/// One tool. Implementations are usually small structs holding a reference to their connector's service.
public protocol AssistantTool: Sendable {
    var definition: ToolDefinition { get }
    /// Runs one call. `input` is Claude's arguments, already parsed (an object matching `inputSchema`, though Claude
    /// can get it wrong: validate and fail with a sentence rather than crash).
    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult
}

/// The tools available for the next request: in the app, the enabled connectors' tools.
public protocol ToolProvider: Sendable {
    func currentTools() async -> [any AssistantTool]
}
