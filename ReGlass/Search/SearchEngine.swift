import Foundation
import SwiftData
import SwiftUI

// Search across the home's three pages: what the owner types in the Search tab, matched against every chat, note,
// reminder and list item on this iPhone. Nothing leaves the phone and nothing is logged: the search runs on plain
// copies of the stores, in memory, as the words change.
//
// A thing matches when it holds the whole of what was typed, or every word of it somewhere (in any order), ignoring
// case and accents, as Notes' search always did. The best matches come first (the whole phrase, then every word in
// one place), newest first among equals; reminders keep their own order (still to come, then done).

// MARK: Terms

/// What was typed, ready to match: the whole of it, trimmed, and its words.
struct SearchTerms: Equatable {
    let phrase: String
    let words: [String]

    init(_ query: String) {
        phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { phrase.isEmpty }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// `text` holds the whole phrase, or every word somewhere in it.
    func matches(_ text: String) -> Bool { strength(text) >= 1 }

    /// How well `text` matches: 2 the whole phrase, 1 every word, 0 some of the words, -1 none.
    func strength(_ text: String) -> Int {
        guard !isEmpty else { return -1 }
        if text.localizedStandardContains(phrase) { return 2 }
        let found = words.filter { text.localizedStandardContains($0) }.count
        if found == words.count { return 1 }
        return found > 0 ? 0 : -1
    }

    /// Where `text` first shows the phrase, else the earliest of its words.
    func firstRange(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: phrase, options: Self.options) { return range }
        return words.compactMap { text.range(of: $0, options: Self.options) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// `text` on one line, starting a little before its first match (at a word, after "…") so the match shows inside
    /// a row's two lines even deep in a long note or reply. Unchanged when the match is near the start, or absent.
    func excerpt(_ text: String, lead: Int = 34) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let range = firstRange(in: flat),
              flat.distance(from: flat.startIndex, to: range.lowerBound) > lead + 8 else { return flat }
        var start = flat.index(range.lowerBound, offsetBy: -lead)
        if let space = flat[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = flat.index(after: space)
        }
        return "…" + flat[start...]
    }

    /// `text` with every word of the search in copper (`Theme.accent`), the rest in `base` (nil: the view's own colour).
    func highlight(_ text: String, base: Color? = nil) -> AttributedString {
        var attributed = AttributedString(text)
        if let base { attributed.foregroundColor = base }
        guard !isEmpty else { return attributed }
        for word in words {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: word, options: Self.options, range: start..<text.endIndex) {
                if let range = Range(found, in: attributed) {
                    attributed[range].foregroundColor = Theme.accent
                }
                start = found.upperBound
            }
        }
        return attributed
    }
}

// MARK: What's searched

/// A conversation as Search reads it: its title and each step's words, in order.
struct ChatDocument {
    struct Line {
        let id: UUID
        let kind: ChatEntry.Kind
        /// What was said, or what ReGlass did and its detail.
        let text: String
    }

    let id: UUID
    let title: String
    let updated: Date
    let lines: [Line]

    init(_ conversation: Conversation) {
        let entries = conversation.orderedEntries
        id = conversation.id
        title = ChatsView.title(of: conversation, entries)
        updated = conversation.updatedAt
        lines = entries.map { entry in
            let detail = entry.kind == .action ? entry.detail.flatMap { $0.isEmpty ? nil : $0 } : nil
            return Line(id: entry.id, kind: entry.kind, text: detail.map { entry.text + " · " + $0 } ?? entry.text)
        }
    }
}

/// Plain copies of ReGlass's library, read when Search opens and again whenever the library changes: what's in the
/// lists (`load`), or what waits in Recently Deleted (`loadDeleted`).
struct SearchLibrary {
    var notes: [NoteSnapshot] = []
    var reminders: [ReminderSnapshot] = []
    var items: [ItemSnapshot] = []

    @MainActor
    static func load() -> SearchLibrary {
        let store = LibraryStore.shared
        return SearchLibrary(notes: store.fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.deletedAt == nil })).map(\.snapshot),
                             reminders: store.fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt == nil })).map(\.snapshot),
                             items: store.fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt == nil })).map(\.snapshot))
    }

    @MainActor
    static func loadDeleted() -> SearchLibrary {
        let store = LibraryStore.shared
        store.purgeDeleted()
        return SearchLibrary(notes: store.deletedNotes(), reminders: store.deletedReminders(), items: store.deletedItems())
    }

    /// Everything on the Reminders page: reminders and list items.
    var reminderCount: Int { reminders.count + items.count }
}

// MARK: Results

/// Which page a result comes from; nil in the chips is All.
enum SearchScope: String, CaseIterable, Identifiable, Hashable {
    case chats, notes, reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return HomePage.chats.symbol
        case .notes: return HomePage.notes.symbol
        case .reminders: return HomePage.reminders.symbol
        }
    }

    /// "chat" / "chats", for "Show all 9 chats".
    func noun(_ count: Int) -> String {
        let one: String
        switch self {
        case .chats: one = "chat"
        case .notes: one = "note"
        case .reminders: one = "reminder"
        }
        return count == 1 ? one : one + "s"
    }
}

/// A conversation that matches, and the step that matches best (nil when only its title does).
struct ChatHit: Identifiable {
    let id: UUID
    let title: String
    let updated: Date
    /// "You", "Glasses", "Them"; nil for what ReGlass did.
    let speaker: String?
    let excerpt: String
    let entry: UUID?
}

/// A note that matches.
struct NoteHit: Identifiable {
    let note: NoteSnapshot
    let excerpt: String
    var id: UUID { note.id }
}

/// A reminder or a list item that matches.
enum ReminderHit: Identifiable {
    case reminder(ReminderSnapshot)
    case item(ItemSnapshot)

    var id: UUID {
        switch self {
        case .reminder(let reminder): return reminder.id
        case .item(let item): return item.id
        }
    }

    var title: String {
        switch self {
        case .reminder(let reminder): return reminder.title
        case .item(let item): return item.title
        }
    }

    /// Its category, trimmed; nil for none.
    var category: String? {
        let name: String?
        switch self {
        case .reminder(let reminder): name = reminder.category
        case .item(let item): name = item.category
        }
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var isOpen: Bool {
        switch self {
        case .reminder(let reminder): return reminder.isOpen
        case .item(let item): return item.isOpen
        }
    }
}

/// Everything that matches, page by page.
struct SearchResults {
    var chats: [ChatHit] = []
    var notes: [NoteHit] = []
    var reminders: [ReminderHit] = []

    var isEmpty: Bool { chats.isEmpty && notes.isEmpty && reminders.isEmpty }

    func count(_ scope: SearchScope) -> Int {
        switch scope {
        case .chats: return chats.count
        case .notes: return notes.count
        case .reminders: return reminders.count
        }
    }

    /// The pages with something found, in the tabs' order.
    var scopes: [SearchScope] { SearchScope.allCases.filter { count($0) > 0 } }
}

// MARK: Searching

enum ReGlassSearch {
    /// Everything matching `terms`, leaving out what's waiting out its Undo (`hidden`).
    static func find(_ terms: SearchTerms, chats: [ChatDocument], library: SearchLibrary,
                     hidden: Set<UUID>) -> SearchResults {
        guard !terms.isEmpty else { return SearchResults() }
        return SearchResults(chats: findChats(terms, chats.filter { !hidden.contains($0.id) }),
                             notes: findNotes(terms, library.notes.filter { !hidden.contains($0.id) }),
                             reminders: findReminders(terms,
                                                      library.reminders.filter { !hidden.contains($0.id) },
                                                      library.items.filter { !hidden.contains($0.id) }))
    }

    private static func findChats(_ terms: SearchTerms, _ chats: [ChatDocument]) -> [ChatHit] {
        var found: [(hit: ChatHit, rank: Int)] = []
        for chat in chats {
            let all = ([chat.title] + chat.lines.map(\.text)).joined(separator: "\n")
            guard terms.matches(all) else { continue }
            // The step that matches best; the first of equals.
            var best: (line: ChatDocument.Line, strength: Int)?
            for line in chat.lines {
                let strength = terms.strength(line.text)
                if strength >= 0, strength > (best?.strength ?? -1) { best = (line, strength) }
            }
            let title = terms.strength(chat.title)
            let hit: ChatHit
            if let best {
                hit = ChatHit(id: chat.id, title: chat.title, updated: chat.updated, speaker: speaker(best.line.kind),
                              excerpt: terms.excerpt(best.line.text), entry: best.line.id)
            } else {
                // Only the title: the last reply, as the Chats row shows.
                let reply = chat.lines.last { $0.kind == .reply } ?? chat.lines.last
                hit = ChatHit(id: chat.id, title: chat.title, updated: chat.updated,
                              speaker: reply.flatMap { speaker($0.kind) },
                              excerpt: reply.map { terms.excerpt($0.text) } ?? "", entry: nil)
            }
            found.append((hit, max(title, best?.strength ?? -1)))
        }
        return found.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.hit.updated > $1.hit.updated }.map(\.hit)
    }

    private static func speaker(_ kind: ChatEntry.Kind) -> String? {
        switch kind {
        case .user: return "You"
        case .reply: return "Glasses"
        case .other: return "Them"
        case .action: return nil
        }
    }

    private static func findNotes(_ terms: SearchTerms, _ notes: [NoteSnapshot]) -> [NoteHit] {
        var found: [(hit: NoteHit, rank: Int)] = []
        for note in notes {
            let filed = [note.category, note.topic].compactMap { $0 }.joined(separator: " ")
            let all = [note.title ?? "", note.text, filed].joined(separator: "\n")
            guard terms.matches(all) else { continue }
            // The words under the heading, from the first match when it's deep in them.
            let body: String
            if let title = note.title, !title.isEmpty {
                body = note.text
            } else {
                let parts = note.text.split(separator: "\n", maxSplits: 1)
                body = parts.count > 1 ? String(parts[1]) : ""
            }
            let rank = max(terms.strength(note.title ?? ""), terms.strength(note.text))
            found.append((NoteHit(note: note, excerpt: terms.excerpt(body)), rank))
        }
        return found.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.hit.note.created > $1.hit.note.created }
            .map(\.hit)
    }

    /// Still to come first (reminders soonest, then list items newest), then the ones done or gone off, latest first.
    private static func findReminders(_ terms: SearchTerms, _ reminders: [ReminderSnapshot],
                                      _ items: [ItemSnapshot]) -> [ReminderHit] {
        let reminders = reminders.filter { terms.matches($0.title + "\n" + ($0.category ?? "")) }
        let items = items.filter { terms.matches([$0.title, $0.category, $0.topic ?? ""].joined(separator: "\n")) }
        let open = reminders.filter(\.isOpen).sorted { $0.due < $1.due }.map(ReminderHit.reminder)
            + items.filter(\.isOpen).sorted { $0.created > $1.created }.map(ReminderHit.item)
        let done: [(hit: ReminderHit, at: Date)] =
            reminders.filter { !$0.isOpen }.map { (.reminder($0), $0.completed ?? $0.fired ?? $0.due) }
            + items.filter { !$0.isOpen }.map { (.item($0), $0.completed ?? $0.created) }
        return open + done.sorted { $0.at > $1.at }.map(\.hit)
    }
}
