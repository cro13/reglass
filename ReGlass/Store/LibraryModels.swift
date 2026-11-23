import Foundation
import SwiftData

// The owner's own notes and reminders: ReGlass's library, kept apart from Chats. A note is something to keep ("take a
// note: …", or typed); a reminder is something to be told about at a time ("remind me in six minutes to check on the
// food"); a list item is something to do or buy with no time, ticked off when done ("I need to buy batteries"). Chats
// only record that a note was taken or a reminder set.
//
// Each of them can carry one category ("Shopping", "Ideas"; see `LibraryCategory`), and notes and items an optional
// one- or two-word topic ("Garden" in "Ideas · Garden"). A category is only a name: there's no category model.
//
// The library is kept on this iPhone only, unless the build turns iCloud sync on (`REGLASS_ICLOUD`, see
// `LibraryStore.cloudKitDatabase` and docs/ICLOUD.md). So the models follow CloudKit's rules: every property has a
// default or is optional, nothing is `.unique`, no relationships. Add a property only with a default; never rename or retype one (iCloud would keep the old field,
// and other devices would still send it).

/// Where a note or reminder came from.
enum LibrarySource: String, CaseIterable, Sendable {
    /// Said to the glasses.
    case voice
    /// Typed in ReGlass on the iPhone.
    case typed
}

/// One note: an idea or something to keep.
@Model
final class ReGlassNote {
    var id: UUID = UUID()
    /// The note itself: as said (fillers dropped, nothing summarised away), or as typed or edited.
    var text: String = ""
    /// A few words for the list ("Bike rack idea"), written by Claude; nil: lists show the first line of `text`.
    var title: String?
    var created: Date = Date.now
    var updated: Date = Date.now
    /// `LibrarySource` raw value.
    var sourceRaw: String = LibrarySource.voice.rawValue
    /// The category's name as shown ("Ideas"); nil: none yet (shown under All only).
    var category: String?
    /// One or two words narrowing the category ("Garden" in "Ideas · Garden"); nil: none.
    var topic: String?
    /// When it was deleted: it waits in Recently Deleted for `LibraryStore.keepDeletedDays`, then it's erased. Nil: in
    /// its list.
    var deletedAt: Date?

    init(text: String, title: String? = nil, category: String? = nil, topic: String? = nil, source: LibrarySource,
         at date: Date = .now) {
        self.id = UUID()
        self.text = text
        self.title = title
        self.category = category
        self.topic = topic
        self.created = date
        self.updated = date
        self.sourceRaw = source.rawValue
    }

    var source: LibrarySource { LibrarySource(rawValue: sourceRaw) ?? .voice }

    /// When it was last changed, if that was more than a minute after it was written (fixing a word straight away
    /// isn't worth showing); nil otherwise, and for a change dated before the note itself.
    var modified: Date? {
        updated.timeIntervalSince(created) > 60 ? updated : nil
    }

    /// The title, or else the first line of the text.
    var heading: String {
        if let title, !title.isEmpty { return title }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}

/// One reminder: something to be told about at `due`.
///
/// Its life: open (to come) → `fired` (it went off: spoken on the glasses, rung or notified) and/or `completed`
/// (ticked off). Ticking off an open reminder means it never goes off. Cancelling deletes it: it waits in Recently
/// Deleted, never going off, and can be put back.
@Model
final class ReGlassReminder {
    var id: UUID = UUID()
    /// What it's for, in a few words ("check on the food").
    var title: String = ""
    /// What the voice says when it's due, written by Claude when it was set ("Time to check on the food."); nil: the
    /// standard line with the title.
    var announcement: String?
    var due: Date = Date.now
    var created: Date = Date.now
    /// When it went off. Nil: hasn't yet.
    var fired: Date?
    /// When the owner ticked it off.
    var completed: Date?
    /// `LibrarySource` raw value.
    var sourceRaw: String = LibrarySource.voice.rawValue
    /// The category's name as shown ("Appointments"); nil: none (shown under All only).
    var category: String?
    /// When it was deleted or cancelled (as `ReGlassNote.deletedAt`). A deleted reminder never goes off.
    var deletedAt: Date?

    init(title: String, due: Date, announcement: String? = nil, category: String? = nil, source: LibrarySource,
         at date: Date = .now) {
        self.id = UUID()
        self.title = title
        self.announcement = announcement
        self.category = category
        self.due = due
        self.created = date
        self.sourceRaw = source.rawValue
    }

    var source: LibrarySource { LibrarySource(rawValue: sourceRaw) ?? .voice }
    /// Still to come: neither gone off nor ticked off.
    var isOpen: Bool { fired == nil && completed == nil }
}

/// One thing to do or buy, with no time: a line on a checklist ("Batteries" on Shopping, "Call the bank" on To-do),
/// ticked off when done. Never goes off, so the reminder scheduler never sees it; one with a day or time is a
/// `ReGlassReminder` instead.
@Model
final class ReGlassItem {
    var id: UUID = UUID()
    /// A few words, first letter capitalised ("Oat milk").
    var title: String = ""
    /// The category's name as shown; every item has one.
    var category: String = LibraryCategory.toDo
    /// One or two words narrowing the category; nil: none.
    var topic: String?
    var created: Date = Date.now
    /// When it was ticked off. Nil: still open.
    var completed: Date?
    /// `LibrarySource` raw value.
    var sourceRaw: String = LibrarySource.voice.rawValue
    /// When it was deleted or cleared (as `ReGlassNote.deletedAt`).
    var deletedAt: Date?

    init(title: String, category: String, topic: String? = nil, source: LibrarySource, at date: Date = .now) {
        self.id = UUID()
        self.title = title
        self.category = category
        self.topic = topic
        self.created = date
        self.sourceRaw = source.rawValue
    }

    var source: LibrarySource { LibrarySource(rawValue: sourceRaw) ?? .voice }
    var isOpen: Bool { completed == nil }
}

// MARK: Snapshots

// Plain copies for code off the main actor (tools, the scheduler). SwiftUI views use the
// models directly through `@Query`.

struct NoteSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let title: String?
    let created: Date
    let updated: Date
    let source: LibrarySource
    var category: String? = nil
    var topic: String? = nil
    var deletedAt: Date? = nil

    var heading: String {
        if let title, !title.isEmpty { return title }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// As `ReGlassNote.modified`: when it was last changed, if that was more than a minute after it was written.
    var modified: Date? {
        updated.timeIntervalSince(created) > 60 ? updated : nil
    }
}

struct ReminderSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let announcement: String?
    let due: Date
    let created: Date
    let fired: Date?
    let completed: Date?
    let source: LibrarySource
    var category: String? = nil
    var deletedAt: Date? = nil

    var isOpen: Bool { fired == nil && completed == nil }
}

struct ItemSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let category: String
    let topic: String?
    let created: Date
    let completed: Date?
    let source: LibrarySource
    var deletedAt: Date? = nil

    var isOpen: Bool { completed == nil }
}

extension ReGlassNote {
    var snapshot: NoteSnapshot {
        NoteSnapshot(id: id, text: text, title: title, created: created, updated: updated, source: source,
                     category: category, topic: topic, deletedAt: deletedAt)
    }
}

extension ReGlassReminder {
    var snapshot: ReminderSnapshot {
        ReminderSnapshot(id: id, title: title, announcement: announcement, due: due, created: created, fired: fired,
                         completed: completed, source: source, category: category, deletedAt: deletedAt)
    }
}

extension ReGlassItem {
    var snapshot: ItemSnapshot {
        ItemSnapshot(id: id, title: title, category: category, topic: topic, created: created, completed: completed,
                     source: source, deletedAt: deletedAt)
    }
}
