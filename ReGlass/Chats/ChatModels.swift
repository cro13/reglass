import Foundation
import SwiftData

// The conversations had through the glasses, stored on this iPhone with SwiftData (see `ChatHistory`).
//
// A conversation is an ordered list of entries: what the user said, what ReGlass did about it, and what the glasses
// said back. It can hold one exchange or many; how turns group into conversations is the voice layer's decision,
// not the store's. Enums are kept as raw strings so a value a later version adds still opens in an older one.

/// One conversation through the glasses.
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    /// The last time anything was added or changed. The history is sorted and grouped by it.
    var updatedAt: Date
    /// Nil while the conversation is still going.
    var endedAt: Date?
    /// Short, from the first thing the user said, unless the voice layer sets its own.
    var title: String
    /// When the owner deleted it: it waits in Recently Deleted for `ChatHistory.keepDeletedDays`, then it's erased.
    /// Nil: in Chats.
    var deletedAt: Date?
    var triggerRaw: String
    @Relationship(deleteRule: .cascade, inverse: \ChatEntry.conversation)
    var entries: [ChatEntry] = []

    init(id: UUID = UUID(), trigger: ChatTrigger, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.title = ""
        self.triggerRaw = trigger.rawValue
    }

    var trigger: ChatTrigger { ChatTrigger(rawValue: triggerRaw) ?? .unknown }

    /// SwiftData keeps relationships unordered; `position` holds the order.
    var orderedEntries: [ChatEntry] { entries.sorted { $0.position < $1.position } }
}

/// One step of a conversation.
@Model
final class ChatEntry {
    @Attribute(.unique) var id: UUID
    /// The order within the conversation, from 0.
    var position: Int
    var kindRaw: String
    /// What the user said, the action's title ("Searched the web for …"), or what the glasses replied.
    var text: String
    /// When it was said or, for an action, when it started.
    var createdAt: Date
    // Actions only.
    var actionKindRaw: String?
    var detail: String?
    var statusRaw: String?
    var finishedAt: Date?
    var conversation: Conversation?

    init(id: UUID = UUID(), position: Int, kind: Kind, text: String, createdAt: Date) {
        self.id = id
        self.position = position
        self.kindRaw = kind.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    enum Kind: String {
        /// The user's transcribed speech.
        case user
        /// Something ReGlass did: a search, music, a light, an alarm…
        case action
        /// What the glasses said back.
        case reply
        /// Someone else's transcribed speech: the other person in a live interpreter session. Older versions of
        /// ReGlass read it as a reply.
        case other

        /// Starts a new exchange in the conversation: someone spoke.
        var startsExchange: Bool { self == .user || self == .other }
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .reply }
    var actionKind: ChatActionKind {
        let kind = actionKindRaw.flatMap(ChatActionKind.init(rawValue:)) ?? .other
        // Before `.problem`, ReGlass filed its own answer's failures as `.other`; they read as what they were.
        return kind == .other && ChatActionKind.problemTitles.contains(text) ? .problem : kind
    }
    var status: ChatActionStatus { statusRaw.flatMap(ChatActionStatus.init(rawValue:)) ?? .done }
}

/// How a conversation started.
enum ChatTrigger: String, CaseIterable {
    case heyMeta
    /// A tap or press on the glasses.
    case touch
    /// Typed in Chats, or in Settings → Talk to ReGlass.
    case typed
    case unknown

    /// For the conversation's header: "Started with “Hey Meta”".
    var startedLabel: String {
        switch self {
        case .heyMeta: return "Started with “Hey Meta”"
        case .touch: return "Started with a tap on your glasses"
        case .typed: return "Typed on your iPhone"
        case .unknown: return "Started on your glasses"
        }
    }

    var symbol: String {
        switch self {
        case .heyMeta: return "waveform"
        case .touch: return "hand.tap"
        case .typed: return "keyboard"
        case .unknown: return "eyeglasses"
        }
    }
}

/// What kind of thing an action did. Decides its symbol; the title says the rest.
enum ChatActionKind: String, CaseIterable {
    case search, music, alarm, timer, reminder, calendar, weather, note
    /// The live interpreter.
    case interpreter
    /// ReGlass's own answer went wrong: Claude couldn't be reached, declined, or was cut short.
    case problem
    case other

    /// The titles `ChatRecorder` gave the answer's failures, which were filed as `other` before `problem` existed.
    static let problemTitles: Set<String> = [
        "Couldn't get an answer from Claude", "Claude declined to answer", "The answer was cut short",
    ]

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .music: return "music.note"
        case .alarm: return "alarm"
        case .timer: return "timer"
        case .reminder: return "checklist"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun"
        case .note: return "note.text"
        case .interpreter: return "character.bubble"
        case .problem: return "exclamationmark.bubble"
        case .other: return "bolt"
        }
    }

    /// For VoiceOver: "Actions: music, search".
    var spokenName: String {
        switch self {
        case .search: return "search"
        case .music: return "music"
        case .alarm: return "alarm"
        case .timer: return "timer"
        case .reminder: return "reminder"
        case .calendar: return "calendar"
        case .weather: return "weather"
        case .note: return "note"
        case .interpreter: return "interpreter"
        case .problem: return "problem"
        case .other: return "other"
        }
    }
}

/// Where an action got to. Always shown in words, with colour only beside them.
enum ChatActionStatus: String, CaseIterable {
    case running, done, failed, cancelled
    /// Still running when ReGlass last stopped (the app was closed mid-action). Set at launch, never by the voice layer.
    case interrupted

    var label: String {
        switch self {
        case .running: return "In progress"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Didn't finish"
        }
    }

    var isFinished: Bool { self != .running }
}
