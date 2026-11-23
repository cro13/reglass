import Foundation
import ReGlassAssistant

/// Writes one assistant conversation into Chats: what was said or typed, each web search, page read and iPhone tool call
/// as an action, and what was actually spoken back. Content goes to the chat store only, never to the activity log.
///
/// Follow-up requests repeat `addUser`, events and `finishExchange` in the same conversation before `end`.
@MainActor
final class ChatRecorder {
    private let history = ChatHistory.shared
    private let chat: ChatHistory.ConversationHandle
    private var searches: [String: (action: ChatHistory.ActionHandle, query: String)] = [:]
    private var fetches: [String: (action: ChatHistory.ActionHandle, url: String)] = [:]
    private var toolCalls: [String: ChatHistory.ActionHandle] = [:]
    private var ended = false

    init(trigger: ChatTrigger, startedAt: Date) {
        chat = history.beginConversation(trigger: trigger, at: startedAt)
    }

    /// Adds to a conversation already in Chats (a reply typed there), open again until `end`. Nil when it's been
    /// deleted.
    init?(continuing id: UUID) {
        guard let chat = ChatHistory.shared.reopenConversation(id) else { return nil }
        self.chat = chat
    }

    /// The chat's id in the store.
    var conversationID: UUID { chat.id }

    func addUser(_ text: String) {
        history.addUserTranscript(text, to: chat)
    }

    // interpreter: someone else's words, a reply that isn't a TurnOutcome, and the chat's title
    func addOther(_ text: String) {
        history.addOtherTranscript(text, to: chat)
    }

    func addReply(_ text: String) {
        history.addAssistantReply(text, to: chat)
    }

    func setTitle(_ title: String) {
        history.setTitle(title, for: chat)
    }

    func handle(_ event: TurnEvent) {
        switch event {
        case .searchStarted(let id, let query):
            let action = history.startAction(.search, title: Self.searchTitle(query, done: false), in: chat)
            searches[id] = (action, query)
        case .searchFinished(let id, let count):
            guard let search = searches[id] else { return }
            history.finishAction(search.action, title: Self.searchTitle(search.query, done: true),
                                 detail: count == 0 ? "No results" : "\(count) result\(count == 1 ? "" : "s")")
        case .searchFailed(let id, let reason):
            guard let search = searches[id] else { return }
            history.failAction(search.action, title: Self.searchTitle(search.query, done: true), detail: reason)
        case .fetchStarted(let id, let url):
            let action = history.startAction(.search, title: Self.fetchTitle(url, done: false), in: chat)
            fetches[id] = (action, url)
        case .fetchFinished(let id, _):
            guard let fetch = fetches[id] else { return }
            history.finishAction(fetch.action, title: Self.fetchTitle(fetch.url, done: true), detail: nil)
        case .fetchFailed(let id, let reason):
            guard let fetch = fetches[id] else { return }
            history.failAction(fetch.action, title: Self.fetchTitle(fetch.url, done: true), detail: reason)
        case .toolStarted(let id, let name):
            toolCalls[id] = history.startAction(Self.toolKind(name), title: Self.toolTitle(name), in: chat)
        case .toolFinished(let id, let name, let result):
            guard let action = toolCalls.removeValue(forKey: id) else { return }
            let line = Self.toolLine(name, result: result)
            if result.isError {
                history.failAction(action, title: line.title, detail: line.detail)
            } else {
                history.finishAction(action, title: line.title, detail: line.detail)
            }
        default:
            break
        }
    }

    // MARK: Tool actions (also used by Talk to ReGlass)

    /// A running tool call's title, from its name: "set_timer" → "Set timer".
    static func toolTitle(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A finished call's line: the tool's own action, else its name, with the failure sentence as the detail.
    static func toolLine(_ name: String, result: ToolResult) -> (title: String, detail: String?) {
        if let action = result.action { return (action.title, action.detail) }
        let content = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // A failure's content is one plain sentence for Claude; show it unless it's data.
        let sentence = result.isError && content.count <= 160 && !content.hasPrefix("{") && !content.hasPrefix("[")
        return (toolTitle(name), sentence ? content : nil)
    }

    /// The action's symbol, from the connector that owns the tool.
    static func toolKind(_ name: String) -> ChatActionKind {
        let owner = ConnectorRegistry.shared.connectors.first { connector in
            connector.tools.contains { $0.definition.name == name }
        }
        switch owner?.id {
        case "timers"?: return .timer
        case "alarms"?: return .alarm
        case "reminders"?: return .reminder
        case "reglass-reminders"?: return .reminder
        case "notes"?: return .note
        case "calendar"?: return .calendar
        case "music"?: return .music
        case "weather"?: return .weather
        case "interpreter"?: return .interpreter
        default: return .other
        }
    }

    /// The reply for this exchange (what was spoken, apology included) and, when it went wrong, why.
    func finishExchange(_ outcome: TurnOutcome?) {
        guard let outcome else { return }
        switch outcome.kind {
        case .failed(let error):
            let action = history.startAction(.problem, title: "Couldn't get an answer from Claude", in: chat)
            history.failAction(action, detail: error.explanation)
        case .refused:
            let action = history.startAction(.problem, title: "Claude declined to answer", in: chat)
            history.failAction(action, detail: "Claude can't help with this request.")
        case .cutShort:
            let action = history.startAction(.problem, title: "The answer was cut short", in: chat)
            history.failAction(action, detail: "It reached its length limit.")
        case .answered, .empty, .cancelled:
            break
        }
        history.addAssistantReply(outcome.spokenText, to: chat)
    }

    /// A conversation from Chats as a note for Claude, when a reply typed there can't replay the Claude conversation
    /// behind it (it's from before this launch, the live interpreter): what was said and done, oldest
    /// first, the oldest lines dropped past about 3,000 characters. Nil when there's nothing in it.
    static func earlierNote(_ id: UUID) -> String? {
        guard let conversation = ChatHistory.shared.conversation(id) else { return nil }
        var lines: [String] = []
        for entry in conversation.orderedEntries {
            switch entry.kind {
            case .user: lines.append("Owner: " + entry.text)
            case .other: lines.append("Someone else: " + entry.text)
            case .reply: lines.append("ReGlass: " + entry.text)
            case .action:
                let detail = entry.detail.map { ", " + $0 } ?? ""
                lines.append("[\(entry.text) (\(entry.status.label)\(detail))]")
            }
        }
        guard !lines.isEmpty else { return nil }
        var kept: [String] = []
        var characters = 0
        for line in lines.reversed() {
            guard characters + line.count <= 3000 || kept.isEmpty else { break }
            kept.insert(line, at: 0)
            characters += line.count
        }
        let start = conversation.startedAt
        let began = "was \(conversation.trigger.startedLabel.prefix(1).lowercased() + conversation.trigger.startedLabel.dropFirst())"
        return "<context>The owner typed this in Chats on their iPhone, going on with an earlier conversation from "
            + "\(start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())), which \(began). "
            + "It went\(kept.count < lines.count ? " (its start left out)" : ""):\n" + kept.joined(separator: "\n")
            + "\nTheir new message may follow up on it or be about something else; decide from the words.</context>"
    }

    /// Closes the conversation. Searches still running are marked cancelled.
    func end() {
        guard !ended else { return }
        ended = true
        history.endConversation(chat)
    }

    /// "Reading ft.com" / "Read ft.com": the page's site, not its whole address.
    static func fetchTitle(_ url: String, done: Bool) -> String {
        let verb = done ? "Read" : "Reading"
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "\(verb) a web page" }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "\(verb) \(site)"
    }

    private static func searchTitle(_ query: String, done: Bool) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = done ? "Searched the web" : "Searching the web"
        return query.isEmpty ? verb : "\(verb) for \u{201C}\(query)\u{201D}"
    }
}
