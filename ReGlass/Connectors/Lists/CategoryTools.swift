import Foundation
import ReGlassAssistant

// Categories for Claude's tools: turning the category Claude passes into one of the owner's (`LibraryCategory`), what
// was captured last (`LastCapture`), and `move_to_category` for "that's not shopping, it's for the office".
//
// Claude picks a category from the list in the context note (`ClaudeTurnContext.categories`) and never invents one: a
// name that isn't there yet becomes a new category only because the owner named it. The voice then
// says where it went, so a wrong pick is caught at once and moved in one sentence.
//
// move_to_category is registered by the Notes connector (Connectors/Notes/NotesConnector.swift), not by Lists: Notes
// has never needed setup or permission, while the Lists switch carries over from when it reached Apple Reminders, so
// the owner may have switched it off back then. Corrections then still work for notes and reminders.

/// The last thing captured by voice or a typed line (a note, a reminder, or the items of one add_to_list), for five
/// minutes, so "that's not shopping, it's for the office" moves exactly that and never guesses. Written by take_note,
/// set_reminder and add_to_list (and moved along by move_to_category); read by move_to_category with `last`.
///
/// Only in memory: after five minutes, or after a restart, "that" means nothing and Claude asks.
@MainActor
enum LastCapture {
    enum Kind: String, Sendable {
        case item, note, reminder
    }

    struct Entry: Sendable, Equatable {
        let kind: Kind
        /// What was captured: one note or reminder, or every item one call added (or found already on the list).
        let ids: [UUID]
        let at: Date
    }

    /// How long "that" points at the last capture.
    static let keep: TimeInterval = 5 * 60

    private static var entry: Entry?

    static func record(_ kind: Kind, ids: [UUID], at date: Date = .now) {
        guard !ids.isEmpty else { return }
        entry = Entry(kind: kind, ids: ids, at: date)
    }

    /// The last capture, if it was within `keep`.
    static func current(now: Date = .now) -> Entry? {
        guard let entry, now.timeIntervalSince(entry.at) < keep else { return nil }
        return entry
    }
}

enum CategoryTools {
    /// What the category Claude passed comes to.
    enum Choice: Sendable, Equatable {
        /// None was passed.
        case none
        /// One of the owner's categories (`isNew`: the owner just named it, and it's started now).
        case use(String, isNew: Bool)
        /// Can't be used: one plain sentence for Claude.
        case refused(String)
    }

    /// Resolves `value` among the owner's categories: the same name, a known other word ("groceries", "the office") or
    /// a slip away; otherwise a new category, unless there are `LibraryCategory.limit` already. `nothing` ends the
    /// refusal ("Nothing was added.").
    @MainActor
    static func resolve(_ value: JSONValue?, nothing: String) -> Choice {
        guard let raw = text(value) else { return .none }
        switch LibraryCategory.resolve(raw, among: LibraryStore.shared.categoryNames()) {
        case .existing(let name):
            return .use(name, isNew: false)
        case .new(let name):
            return .use(name, isNew: true)
        case .full:
            return .refused("ReGlass already has \(LibraryCategory.limit) categories, so it can't start \u{201C}\(raw)\u{201D}. "
                            + "\(nothing) Use one of the categories in the context note.")
        case .empty:
            return .none
        }
    }

    /// An existing category `value` means, without starting one: for reading and finding.
    @MainActor
    static func existing(_ value: JSONValue?) -> (asked: String?, found: String?) {
        guard let raw = text(value) else { return (nil, nil) }
        return (raw, LibraryCategory.match(raw, among: LibraryStore.shared.categoryNames()))
    }

    /// A topic: one or two words, first letter capitalised ("ReGlass"), at most `LibraryCategory.maxNameLength`
    /// characters; nil when none was given.
    static func topic(_ value: JSONValue?) -> String? {
        guard let raw = text(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”.")), !raw.isEmpty else { return nil }
        let words = raw.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        let short = String(words.prefix(LibraryCategory.maxNameLength))
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    /// The first eight hex digits of an id, lowercased: enough to tell a few things apart, short for Claude to pass
    /// back (as `ReGlassReminderTools.shortID` for reminders).
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// A trimmed, non-empty string, or nil.
    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A bool, also when Claude sends "true".
    static func bool(_ value: JSONValue?) -> Bool? {
        if let bool = value?.bool { return bool }
        switch text(value)?.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: return nil
        }
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: move_to_category

struct MoveToCategoryTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "move_to_category",
            description: """
            Moves something already saved in ReGlass to another category: a list item, a note or a reminder. Use it \
            when the user corrects where ReGlass put something or wants it elsewhere: "that's not shopping, it's for \
            the office", "put that under To-do", "move the batteries to Work", "file my bike rack note under Ideas". \
            For "that" or "it", meaning what ReGlass just added, saved or set, pass last true: ReGlass knows exactly what \
            that was for five minutes. Otherwise pass a few words of its title as words, and kind when the user says \
            it's a note or a reminder. If more than one thing could be meant, nothing moves and the result has \
            needs_choice with candidates, each with an id: ask which, then call again with that id. Not for ticking \
            things off (tick_off_list_item) or moving a reminder to another time (change_reminder). ReGlass confirms \
            aloud by itself, so add nothing after it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "category": [
                        "type": "string",
                        "description": """
                        Where it goes: a category from the context note's list ("the office" is Work, "groceries" is \
                        Shopping). A new category only when the user names one that isn't there.
                        """,
                    ],
                    "topic": [
                        "type": "string",
                        "description": "One or two words narrowing the category, only when the user says one (\"garden\" in \"Ideas for the garden\").",
                    ],
                    "last": [
                        "type": "boolean",
                        "description": "True for \"that\" or \"it\": what ReGlass captured last, within five minutes.",
                    ],
                    "kind": [
                        "type": "string",
                        "enum": ["item", "note", "reminder"],
                        "description": "Only when the user says what it is: a list item, a note or a reminder.",
                    ],
                    "words": [
                        "type": "string",
                        "description": "A few words of its title, such as \"batteries\" or \"bike rack\".",
                    ],
                    "id": [
                        "type": "string",
                        "description": "The id of one candidate from a needs_choice answer, to pick exactly that one.",
                    ],
                ],
                "required": ["category"],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let words = CategoryTools.text(input["words"])
        let id = CategoryTools.text(input["id"])?.lowercased()
        let kind = CategoryTools.text(input["kind"]).flatMap { LastCapture.Kind(rawValue: $0.lowercased()) }
        // Nothing to go by: "move that to Work" means the last capture.
        let last = CategoryTools.bool(input["last"]) ?? (words == nil && id == nil)
        let topic = CategoryTools.topic(input["topic"])
        return await MainActor.run {
            Self.move(category: input["category"], topic: topic, last: last, kind: kind, words: words, id: id)
        }
    }

    /// One thing that can be moved.
    private struct Target {
        let kind: LastCapture.Kind
        let id: UUID
        let title: String
        let category: String?
    }

    @MainActor
    private static func move(category value: JSONValue?, topic: String?, last: Bool, kind: LastCapture.Kind?,
                             words: String?, id: String?) -> ToolResult {
        let failed = { (detail: String) in ToolAction(title: "Couldn't move it", detail: detail) }
        let category: String
        let isNew: Bool
        switch CategoryTools.resolve(value, nothing: "Nothing was moved.") {
        case .none:
            return .failure("Say which category to move it to. Nothing was moved.", action: failed("No category given"))
        case .refused(let sentence):
            return .failure(sentence, action: failed("Too many categories"))
        case .use(let name, let new):
            category = name
            isNew = new
        }

        // What to move: an id from needs_choice; else the last capture (narrowed by words); else words; else the
        // newest of the kind named.
        var targets: [Target] = []
        // The last capture, narrowed by words when given; words that fit none of it mean something else (searched
        // below), not the capture.
        var captured: [Target] = []
        if last, let capture = LastCapture.current(), kind == nil || kind == capture.kind {
            captured = capture.ids.compactMap { target(capture.kind, $0) }
            if let words { captured = best(captured, words: words) }
        }
        if let id, id.count >= 4 {
            targets = everything(kind: kind).filter { CategoryTools.shortID($0.id).hasPrefix(id) || $0.id.uuidString.lowercased() == id }
        } else if !captured.isEmpty {
            targets = captured
        } else if let words {
            targets = best(everything(kind: kind), words: words)
        } else if let kind {
            targets = newest(kind).map { [$0] } ?? []
        } else {
            return .failure("Nothing was captured in the last five minutes, so ReGlass doesn't know what \u{201C}that\u{201D} is. "
                            + "Nothing was moved: ask what to move, or pass words.",
                            action: failed("Nothing captured lately"))
        }

        guard !targets.isEmpty else {
            return .success(CategoryTools.json(["moved": [], "no_match": true,
                                                "note": "Nothing matches. Nothing was moved: ask what to move."]),
                            action: failed("Nothing matched"))
        }
        // Several things that aren't one capture: ask which.
        let fromCapture = last && id == nil && LastCapture.current().map { capture in
            Set(targets.map(\.id)).isSubset(of: Set(capture.ids))
        } == true
        if targets.count > 1, !fromCapture {
            let candidates: [JSONValue] = targets.prefix(6).map { target in
                var entry: [String: JSONValue] = ["id": .string(CategoryTools.shortID(target.id)),
                                                  "kind": .string(target.kind.rawValue), "title": .string(target.title)]
                if let category = target.category { entry["category"] = .string(category) }
                return .object(entry)
            }
            return .success(CategoryTools.json(.object(["moved": [], "needs_choice": .array(candidates)])),
                            action: ToolAction(title: "Asked which to move", detail: "\(targets.count) could be meant"))
        }

        let store = LibraryStore.shared
        var moved: [Target] = []
        for target in targets {
            switch target.kind {
            case .item:
                if store.moveItem(target.id, to: category, topic: topic) != nil { moved.append(target) }
            case .note:
                if store.moveNote(target.id, to: category, topic: topic) != nil { moved.append(target) }
            case .reminder:
                if store.moveReminder(target.id, to: category) != nil { moved.append(target) }
            }
        }
        guard let first = moved.first else {
            return .failure("That couldn't be moved; it may have just been deleted. Nothing was moved.",
                            action: failed("ReGlass couldn't save it"))
        }
        // "No, To-do" right after still means the same thing.
        LastCapture.record(first.kind, ids: moved.map(\.id))
        let reply = "Moved to \(category)\(isNew ? ", a new category" : "")."
        let facts: [String: JSONValue] = [
            "moved": .array(moved.map { target in
                .object(["kind": .string(target.kind.rawValue), "title": .string(target.title),
                         "from": target.category.map(JSONValue.string) ?? .null])
            }),
            "category": .string(category),
            "said": .string(reply),
        ]
        let detail = moved.count == 1 ? display(first) : "\(moved.count) things"
        return .success(CategoryTools.json(.object(facts)), action: ToolAction(title: "Moved to \(category)", detail: detail),
                        spokenReply: reply)
    }

    /// One thing by kind and id, if it's still there (and not on its way out with Undo showing).
    @MainActor
    private static func target(_ kind: LastCapture.Kind, _ id: UUID) -> Target? {
        guard !LibraryToast.shared.hidden.contains(id) else { return nil }
        let store = LibraryStore.shared
        switch kind {
        case .item: return store.item(id).map { Target(kind: .item, id: $0.id, title: $0.title, category: $0.category) }
        case .note: return store.note(id).map { Target(kind: .note, id: $0.id, title: $0.heading, category: $0.category) }
        case .reminder:
            return store.reminder(id).map { Target(kind: .reminder, id: $0.id, title: $0.title, category: $0.category) }
        }
    }

    /// What words can pick from: open list items, reminders still to come, and notes (newest first); of one kind, or all.
    @MainActor
    private static func everything(kind: LastCapture.Kind?) -> [Target] {
        let store = LibraryStore.shared
        let hidden = LibraryToast.shared.hidden
        var all: [Target] = []
        if kind == nil || kind == .item {
            all += store.openItems().filter { !hidden.contains($0.id) }
                .map { Target(kind: .item, id: $0.id, title: $0.title, category: $0.category) }
        }
        if kind == nil || kind == .reminder {
            all += ReGlassReminderTools.upcoming().map { Target(kind: .reminder, id: $0.id, title: $0.title, category: $0.category) }
        }
        if kind == nil || kind == .note {
            all += store.notes(limit: 200).filter { !hidden.contains($0.id) }
                .map { Target(kind: .note, id: $0.id, title: $0.heading, category: $0.category) }
        }
        return all
    }

    /// The best matches for `words` by title (`ReminderTitleMatcher`), all of them when they tie.
    private static func best(_ targets: [Target], words: String) -> [Target] {
        var top = 0
        var matches: [Target] = []
        for target in targets {
            let score = ReminderTitleMatcher.score(query: words, title: target.title)
            if score > top {
                top = score
                matches = [target]
            } else if score == top, score > 0 {
                matches.append(target)
            }
        }
        return top >= 60 ? matches : []
    }

    /// The newest of a kind: the latest note, the reminder set last, the item added last.
    @MainActor
    private static func newest(_ kind: LastCapture.Kind) -> Target? {
        let store = LibraryStore.shared
        let hidden = LibraryToast.shared.hidden
        switch kind {
        case .item:
            return store.openItems().filter { !hidden.contains($0.id) }.max { $0.created < $1.created }
                .map { Target(kind: .item, id: $0.id, title: $0.title, category: $0.category) }
        case .note:
            return store.notes(limit: 1 + hidden.count).first { !hidden.contains($0.id) }
                .map { Target(kind: .note, id: $0.id, title: $0.heading, category: $0.category) }
        case .reminder:
            return ReGlassReminderTools.upcoming().max { $0.created < $1.created }
                .map { Target(kind: .reminder, id: $0.id, title: $0.title, category: $0.category) }
        }
    }

    private static func display(_ target: Target) -> String {
        target.kind == .reminder ? ReminderSpeech.displayTitle(target.title) : target.title
    }
}
