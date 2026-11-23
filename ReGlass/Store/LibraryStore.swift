import CoreData
import Foundation
import SwiftData

/// The owner's notes, reminders and list items (`ReGlassNote`, `ReGlassReminder`, `ReGlassItem`), and the one way to change
/// them.
///
/// Everything that changes the library goes through here: the assistant's tools and the Notes and Reminders screens.
/// Each change saves straight away and posts `LibraryStore.didChange` (also when the persistent store reports a change
/// made elsewhere), so the reminder scheduler can catch up. SwiftUI views read through `@Query` with
/// `.modelContainer(LibraryStore.shared.container)` on their subtree (the app's root environment holds Chats'
/// container).
///
/// Its own store, apart from Chats: Application Support/ReGlass/Library, protected until the iPhone has been unlocked
/// once after a restart, so voice notes save with the iPhone locked in a pocket. On this iPhone only, unless the build
/// turns iCloud sync on (`REGLASS_ICLOUD = YES` in Local.xcconfig, docs/ICLOUD.md): then it also syncs through the
/// owner's private iCloud database (`cloudKitDatabase`); the models follow CloudKit's rules for that. Chats never sync
/// (their store says `.none`).
///
/// Deleting doesn't erase: a deleted note, reminder or item gets `deletedAt` and waits in Recently Deleted for
/// `keepDeletedDays`, left out of every list, count, search and tool, until it's put back or its time
/// is up (`purgeDeleted`). Only Recently Deleted's own Delete erases straight away.
///
/// The activity log gets counts and states only, never what a note or reminder says.
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    /// Posted on the main queue after every change, whoever made it.
    static let didChange = Notification.Name("ReGlassLibraryDidChange")

    let container: ModelContainer
    /// The main context. Extensions insert and delete through it, then call `save(_:)`.
    var context: ModelContext { container.mainContext }
    private let log: (String) -> Void
    private var remoteObserver: NSObjectProtocol?

    /// Application Support/ReGlass/Library. Files created inside take the folder's protection class.
    static let directory = Storage.directory.appendingPathComponent("Library", isDirectory: true)
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    #if REGLASS_ICLOUD
    /// Where the library syncs: the owner's private iCloud database, in the container the entitlements name
    /// (ReGlass-iCloud.entitlements: `iCloud.` + the bundle ID).
    static let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .private(cloudKitContainer)
    static let cloudKitContainer = "iCloud." + (Bundle.main.bundleIdentifier ?? "")
    #else
    /// Where the library syncs: nowhere, this iPhone only. A build with `REGLASS_ICLOUD` syncs it through the owner's
    /// private iCloud database.
    static let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none
    #endif

    /// `log` gets only states and error types. Defaults to ReGlass's activity log.
    init(log activity: ActivityLog? = nil) {
        let activity = activity ?? GlassesController.shared.log
        let log: (String) -> Void = { activity.add($0) }
        self.log = log
        let schema = Schema([ReGlassNote.self, ReGlassReminder.self, ReGlassItem.self])
        var opened: ModelContainer?
        var failure: Error?
        do {
            try LibraryStore.prepareDirectory()
            opened = try LibraryStore.openStore(schema, cloudKitDatabase: LibraryStore.cloudKitDatabase)
            #if REGLASS_ICLOUD
            log("Library: syncs with iCloud (private database)")
            #endif
        } catch {
            failure = error
            #if REGLASS_ICLOUD
            // iCloud wouldn't take the store: keep the library on this iPhone rather than only in memory.
            log("Library couldn't sync with iCloud, so it stays on this iPhone this time (\(type(of: error)))")
            opened = try? LibraryStore.openStore(schema, cloudKitDatabase: .none)
            #endif
        }
        if let opened {
            container = opened
            LibraryStore.protectFiles()
        } else {
            // ReGlass still opens; notes and reminders just don't outlive this launch.
            log("Library couldn't open its store, so this session's notes and reminders won't be kept "
                + "(\(failure.map { "\(type(of: $0))" } ?? "unknown"))")
            container = try! ModelContainer(for: schema,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                               cloudKitDatabase: .none))
        }
        // Changes the persistent store reports from elsewhere (another device, once iCloud sync is on).
        remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        repairNoteDates()
        // Once `shared` exists: erasing posts `didChange`, whose observers (the scheduler) read
        // `LibraryStore.shared`, which mustn't happen while it's still being made.
        Task { @MainActor [weak self] in self?.purgeDeleted() }
    }

    /// A note whose last change reads as earlier than the note itself (one from the first evening came out of a store
    /// upgrade as 1 Jan 2001) gets its creation time back, so its row says when it was written and sorts there.
    private func repairNoteDates() {
        let broken = fetch(FetchDescriptor<ReGlassNote>()).filter { $0.updated < $0.created }
        guard !broken.isEmpty else { return }
        for note in broken { note.updated = note.created }
        save("note dates repaired")
        log("Library: gave \(broken.count) note\(broken.count == 1 ? " its date" : "s their dates") back")
    }

    // MARK: Notes

    /// Saves a new note. Nil if `text` is empty. `category` is a shown name (`LibraryCategory`), already resolved.
    @discardableResult
    func addNote(text: String, title: String? = nil, category: String? = nil, topic: String? = nil,
                 source: LibrarySource, at date: Date = .now) -> NoteSnapshot? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let note = ReGlassNote(text: text, title: Self.clean(title), category: Self.clean(category),
                             topic: Self.clean(topic), source: source, at: date)
        context.insert(note)
        save("note added")
        return note.snapshot
    }

    /// Replaces a note's text and/or title (a nil argument leaves that part as it is; an empty title clears it).
    @discardableResult
    func updateNote(_ id: UUID, text: String? = nil, title: String? = nil, at date: Date = .now) -> NoteSnapshot? {
        guard let note = findNote(id) else { return nil }
        if let text {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return note.snapshot }
            note.text = text
        }
        if let title { note.title = Self.clean(title) }
        note.updated = date
        save("note edited")
        return note.snapshot
    }

    /// Adds `text` to the end of a note, as a new paragraph.
    @discardableResult
    func appendToNote(_ id: UUID, text: String, at date: Date = .now) -> NoteSnapshot? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = findNote(id), !text.isEmpty else { return nil }
        note.text = note.text.isEmpty ? text : note.text + "\n\n" + text
        note.updated = date
        save("note extended")
        return note.snapshot
    }

    /// Into Recently Deleted (`restoreNote` puts it back).
    func deleteNote(_ id: UUID, at date: Date = .now) {
        guard let note = findNote(id) else { return }
        note.deletedAt = date
        save("note deleted")
    }

    func note(_ id: UUID) -> NoteSnapshot? { findNote(id)?.snapshot }

    /// Notes newest first (by last change). With a query: only notes whose title or text contains it (ignoring case
    /// and accents), or contains every word of it.
    func notes(matching query: String? = nil, limit: Int = 50) -> [NoteSnapshot] {
        let all = fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.deletedAt == nil },
                                                   sortBy: [SortDescriptor(\.updated, order: .reverse)]))
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return Array(all.prefix(limit)).map(\.snapshot) }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = all.filter { note in
            let haystack = (note.title ?? "") + "\n" + note.text
            return haystack.localizedStandardContains(query) || words.allSatisfy { haystack.localizedStandardContains($0) }
        }
        return Array(matches.prefix(limit)).map(\.snapshot)
    }

    // MARK: Reminders

    /// Saves a new open reminder. Nil if `title` is empty. `category` is a shown name, already resolved.
    @discardableResult
    func addReminder(title: String, due: Date, announcement: String? = nil, category: String? = nil,
                     source: LibrarySource, at date: Date = .now) -> ReminderSnapshot? {
        guard let title = Self.clean(title) else { return nil }
        let reminder = ReGlassReminder(title: title, due: due, announcement: Self.clean(announcement),
                                     category: Self.clean(category), source: source, at: date)
        context.insert(reminder)
        save("reminder added")
        return reminder.snapshot
    }

    func reminder(_ id: UUID) -> ReminderSnapshot? { findReminder(id)?.snapshot }

    /// Open reminders, soonest first.
    func upcomingReminders() -> [ReminderSnapshot] {
        fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.due)]))
            .filter(\.isOpen).map(\.snapshot)
    }

    /// Reminders that went off or were ticked off, most recent first.
    func earlierReminders(limit: Int = 50) -> [ReminderSnapshot] {
        let done = fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt == nil })).filter { !$0.isOpen }
        let sorted = done.sorted { ($0.fired ?? $0.completed ?? $0.due) > ($1.fired ?? $1.completed ?? $1.due) }
        return Array(sorted.prefix(limit)).map(\.snapshot)
    }

    /// It went off (spoken, rung or notified). Only the first call counts.
    func markFired(_ id: UUID, at date: Date = .now) {
        guard let reminder = findReminder(id), reminder.fired == nil else { return }
        reminder.fired = date
        save("reminder went off")
    }

    /// Ticked off. An open reminder then never goes off (`reopenReminder` undoes it while its time is still ahead).
    func completeReminder(_ id: UUID, at date: Date = .now) {
        guard let reminder = findReminder(id), reminder.completed == nil else { return }
        reminder.completed = date
        save("reminder ticked off")
    }

    /// A new due time; the reminder is open again (not gone off, not ticked off).
    @discardableResult
    func rescheduleReminder(_ id: UUID, to due: Date) -> ReminderSnapshot? {
        changeReminder(id, due: due)
    }

    /// A new due time and/or title (a nil argument leaves that part as it is).
    ///
    /// A new time opens it again (not gone off, not ticked off), so one that already went off comes back for the new
    /// time, and restarts its ring: `created` becomes now, so the ring drains from the move rather than from when it
    /// was first set. A new title drops the line Claude wrote for the old one, so the voice says the new title.
    @discardableResult
    func changeReminder(_ id: UUID, due: Date? = nil, title: String? = nil, at date: Date = .now) -> ReminderSnapshot? {
        guard let reminder = findReminder(id) else { return nil }
        if let due {
            reminder.due = due
            reminder.created = min(date, due)
            reminder.fired = nil
            reminder.completed = nil
        }
        if let title = Self.clean(title), title != reminder.title {
            reminder.title = title
            reminder.announcement = nil
        }
        save(due == nil ? "reminder renamed" : "reminder moved")
        return reminder.snapshot
    }

    /// Not ticked off after all: open again for the time it had. Only for one ticked off before it went off whose
    /// time is still ahead; nil otherwise (nothing changes).
    @discardableResult
    func reopenReminder(_ id: UUID, at date: Date = .now) -> ReminderSnapshot? {
        guard let reminder = findReminder(id), reminder.fired == nil, reminder.completed != nil,
              reminder.due > date else { return nil }
        reminder.completed = nil
        save("reminder reopened")
        return reminder.snapshot
    }

    /// Cancelled: into Recently Deleted, where it never goes off (`restoreReminder` puts it back).
    func deleteReminder(_ id: UUID, at date: Date = .now) {
        guard let reminder = findReminder(id) else { return }
        reminder.deletedAt = date
        save("reminder deleted")
    }

    /// How long a snooze lasts unless the owner says otherwise.
    nonisolated static let snoozeMinutes = 10

    /// Rings again `minutes` from now: the reminder moves there and is open again (`changeReminder`), so its alerts
    /// are placed afresh. Works for one that went off, is ringing or is still to come.
    @discardableResult
    func snoozeReminder(_ id: UUID, for minutes: Int = LibraryStore.snoozeMinutes, at date: Date = .now) -> ReminderSnapshot? {
        let snoozed = changeReminder(id, due: date.addingTimeInterval(TimeInterval(max(1, minutes)) * 60), at: date)
        if snoozed != nil { lastSnooze = (id, date) }
        return snoozed
    }

    /// The reminder snoozed last and when (this launch only), so a second "snooze it for twenty minutes" means the
    /// one just snoozed rather than an older one that went off before it.
    private(set) var lastSnooze: (id: UUID, at: Date)?

    // MARK: List items

    /// Adds things to do or buy to `category` (a shown name, already resolved), in the order given. A title already
    /// open in that category (same words, ignoring case) isn't added twice: it comes back in `alreadyOpen`.
    @discardableResult
    func addItems(_ titles: [String], category: String, topic: String? = nil, source: LibrarySource,
                  at date: Date = .now) -> (added: [ItemSnapshot], alreadyOpen: [ItemSnapshot]) {
        guard let category = Self.clean(category) else { return ([], []) }
        var open = openItems(in: category)
        var added: [ItemSnapshot] = [], already: [ItemSnapshot] = []
        for (index, raw) in titles.enumerated() {
            guard let title = Self.clean(raw) else { continue }
            if let existing = open.first(where: { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                already.append(existing)
                continue
            }
            // A millisecond apart, so the order said is the order shown.
            let item = ReGlassItem(title: title, category: category, topic: Self.clean(topic), source: source,
                                 at: date.addingTimeInterval(Double(index) / 1000))
            context.insert(item)
            added.append(item.snapshot)
            open.append(item.snapshot)
        }
        if !added.isEmpty { save(added.count == 1 ? "item added" : "\(added.count) items added") }
        return (added, already)
    }

    func item(_ id: UUID) -> ItemSnapshot? { findItem(id)?.snapshot }

    /// Open items, oldest first (the order they were added); in one category, or all.
    func openItems(in category: String? = nil) -> [ItemSnapshot] {
        fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.created)]))
            .filter { item in item.isOpen && (category.map { LibraryCategory.same(item.category, $0) } ?? true) }
            .map(\.snapshot)
    }

    /// Ticked-off items, most recently ticked first; in one category, or all.
    func completedItems(in category: String? = nil, limit: Int = 50) -> [ItemSnapshot] {
        let done = fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { item in !item.isOpen && (category.map { LibraryCategory.same(item.category, $0) } ?? true) }
            .sorted { ($0.completed ?? $0.created) > ($1.completed ?? $1.created) }
        return Array(done.prefix(limit)).map(\.snapshot)
    }

    /// Ticks items off; returns the ones that were open (for "put them back").
    @discardableResult
    func completeItems(_ ids: [UUID], at date: Date = .now) -> [ItemSnapshot] {
        let items = ids.compactMap { findItem($0) }.filter(\.isOpen)
        guard !items.isEmpty else { return [] }
        for item in items { item.completed = date }
        save(items.count == 1 ? "item ticked off" : "\(items.count) items ticked off")
        return items.map(\.snapshot)
    }

    /// Not done after all: open again.
    @discardableResult
    func reopenItems(_ ids: [UUID]) -> [ItemSnapshot] {
        let items = ids.compactMap { findItem($0) }.filter { !$0.isOpen }
        guard !items.isEmpty else { return [] }
        for item in items { item.completed = nil }
        save(items.count == 1 ? "item reopened" : "\(items.count) items reopened")
        return items.map(\.snapshot)
    }

    /// A new title (nil or empty leaves it as it is).
    @discardableResult
    func renameItem(_ id: UUID, to title: String?) -> ItemSnapshot? {
        guard let item = findItem(id) else { return nil }
        if let title = Self.clean(title), title != item.title {
            item.title = title
            save("item renamed")
        }
        return item.snapshot
    }

    func deleteItem(_ id: UUID) { deleteItems([id]) }

    /// Into Recently Deleted (the screens offer Undo first; `restoreItems` puts them back).
    func deleteItems(_ ids: [UUID], at date: Date = .now) {
        let items = ids.compactMap { findItem($0) }
        guard !items.isEmpty else { return }
        for item in items { item.deletedAt = date }
        save(items.count == 1 ? "item deleted" : "\(items.count) items deleted")
    }

    // MARK: Categories

    /// Every category: the defaults in their order, then the owner's own in the order first used. An own category
    /// exists while some note, reminder or item outside Recently Deleted carries it.
    func categoryNames() -> [String] {
        var used: [(name: String, first: Date)] = []
        func add(_ name: String?, _ date: Date) {
            guard let name = Self.clean(name), !LibraryCategory.defaults.contains(where: { LibraryCategory.same($0, name) }) else { return }
            if let index = used.firstIndex(where: { LibraryCategory.same($0.name, name) }) {
                if date < used[index].first { used[index].first = date }
            } else {
                used.append((name, date))
            }
        }
        for note in fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.deletedAt == nil })) {
            add(note.category, note.created)
        }
        for reminder in fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt == nil })) {
            add(reminder.category, reminder.created)
        }
        for item in fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt == nil })) {
            add(item.category, item.created)
        }
        return LibraryCategory.defaults + used.sorted { $0.first < $1.first }.map(\.name)
    }

    /// Files a note under `category` (nil: none) with `topic` (nil: none).
    @discardableResult
    func moveNote(_ id: UUID, to category: String?, topic: String? = nil) -> NoteSnapshot? {
        guard let note = findNote(id) else { return nil }
        note.category = Self.clean(category)
        note.topic = Self.clean(topic)
        save("note moved")
        return note.snapshot
    }

    /// Files a reminder under `category` (nil: none). Its alerts don't change.
    @discardableResult
    func moveReminder(_ id: UUID, to category: String?) -> ReminderSnapshot? {
        guard let reminder = findReminder(id) else { return nil }
        reminder.category = Self.clean(category)
        save("reminder moved to a category")
        return reminder.snapshot
    }

    /// Puts an item on another list, with `topic` (nil: none). Every item keeps a category: an empty one changes nothing.
    @discardableResult
    func moveItem(_ id: UUID, to category: String, topic: String? = nil) -> ItemSnapshot? {
        guard let item = findItem(id), let category = Self.clean(category) else { return nil }
        item.category = category
        item.topic = Self.clean(topic)
        save("item moved")
        return item.snapshot
    }

    // MARK: Recently Deleted

    /// How long a deleted note, reminder or item waits in Recently Deleted before it's erased.
    nonisolated static let keepDeletedDays = 30

    /// When something deleted at `deletedAt` is erased.
    nonisolated static func erasedOn(_ deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(TimeInterval(keepDeletedDays) * 86_400)
    }

    /// Deleted notes, most recently deleted first.
    func deletedNotes() -> [NoteSnapshot] {
        fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.deletedAt != nil },
                                         sortBy: [SortDescriptor(\.deletedAt, order: .reverse)])).map(\.snapshot)
    }

    /// Deleted reminders, most recently deleted first.
    func deletedReminders() -> [ReminderSnapshot] {
        fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt != nil },
                                             sortBy: [SortDescriptor(\.deletedAt, order: .reverse)])).map(\.snapshot)
    }

    /// Deleted list items, most recently deleted first.
    func deletedItems() -> [ItemSnapshot] {
        fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt != nil },
                                         sortBy: [SortDescriptor(\.deletedAt, order: .reverse)])).map(\.snapshot)
    }

    /// Out of Recently Deleted, back in its list and category.
    @discardableResult
    func restoreNote(_ id: UUID) -> NoteSnapshot? {
        guard let note = findNote(id, includingDeleted: true), note.deletedAt != nil else { return nil }
        note.deletedAt = nil
        save("note put back")
        return note.snapshot
    }

    /// Out of Recently Deleted. One whose time is still ahead goes off then, as set; one whose time passed while it
    /// was deleted comes back as gone off at its time, under Earlier, so it never rings late.
    @discardableResult
    func restoreReminder(_ id: UUID, at date: Date = .now) -> ReminderSnapshot? {
        guard let reminder = findReminder(id, includingDeleted: true), reminder.deletedAt != nil else { return nil }
        reminder.deletedAt = nil
        if reminder.isOpen, reminder.due <= date { reminder.fired = reminder.due }
        save("reminder put back")
        return reminder.snapshot
    }

    /// Out of Recently Deleted, back on their lists, open or ticked as they were. An open one whose title is already
    /// open on its list again (added anew since) isn't put back twice: the copy on the list stands for it, and the
    /// deleted one is erased.
    @discardableResult
    func restoreItems(_ ids: [UUID]) -> [ItemSnapshot] {
        let items = ids.compactMap { findItem($0, includingDeleted: true) }.filter { $0.deletedAt != nil }
        guard !items.isEmpty else { return [] }
        var back: [ItemSnapshot] = []
        for item in items {
            if item.isOpen, let twin = openItems(in: item.category).first(where: {
                $0.title.compare(item.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                context.delete(item)
                back.append(twin)
            } else {
                item.deletedAt = nil
                back.append(item.snapshot)
            }
        }
        save(items.count == 1 ? "item put back" : "\(items.count) items put back")
        return back
    }

    /// Erased for good, from Recently Deleted. Only something already deleted.
    func eraseNotes(_ ids: [UUID]) {
        let notes = ids.compactMap { findNote($0, includingDeleted: true) }.filter { $0.deletedAt != nil }
        guard !notes.isEmpty else { return }
        for note in notes { context.delete(note) }
        save(notes.count == 1 ? "note erased" : "\(notes.count) notes erased")
    }

    /// Erased for good, from Recently Deleted. Only something already deleted.
    func eraseReminders(_ ids: [UUID]) {
        let reminders = ids.compactMap { findReminder($0, includingDeleted: true) }.filter { $0.deletedAt != nil }
        guard !reminders.isEmpty else { return }
        for reminder in reminders { context.delete(reminder) }
        save(reminders.count == 1 ? "reminder erased" : "\(reminders.count) reminders erased")
    }

    /// Erased for good, from Recently Deleted. Only something already deleted.
    func eraseItems(_ ids: [UUID]) {
        let items = ids.compactMap { findItem($0, includingDeleted: true) }.filter { $0.deletedAt != nil }
        guard !items.isEmpty else { return }
        for item in items { context.delete(item) }
        save(items.count == 1 ? "item erased" : "\(items.count) items erased")
    }

    /// Erases what has waited in Recently Deleted longer than `keepDeletedDays`. At launch and as Recently Deleted
    /// opens.
    func purgeDeleted(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.keepDeletedDays) * 86_400)
        let notes = fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.deletedAt != nil }))
            .filter { ($0.deletedAt ?? now) < cutoff }
        let reminders = fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.deletedAt != nil }))
            .filter { ($0.deletedAt ?? now) < cutoff }
        let items = fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.deletedAt != nil }))
            .filter { ($0.deletedAt ?? now) < cutoff }
        let count = notes.count + reminders.count + items.count
        guard count > 0 else { return }
        for note in notes { context.delete(note) }
        for reminder in reminders { context.delete(reminder) }
        for item in items { context.delete(item) }
        save("old deletions erased")
        log("Library: erased \(count) thing\(count == 1 ? "" : "s") deleted over \(Self.keepDeletedDays) days ago")
    }

    // MARK: Shared with extensions (LibraryStore+….swift)

    /// The note with `id`; one in Recently Deleted only with `includingDeleted`, so edits and tools treat a
    /// deleted note as gone.
    func findNote(_ id: UUID, includingDeleted: Bool = false) -> ReGlassNote? {
        let note = fetch(FetchDescriptor<ReGlassNote>(predicate: #Predicate { $0.id == id })).first
        return includingDeleted || note?.deletedAt == nil ? note : nil
    }

    /// As `findNote`.
    func findReminder(_ id: UUID, includingDeleted: Bool = false) -> ReGlassReminder? {
        let reminder = fetch(FetchDescriptor<ReGlassReminder>(predicate: #Predicate { $0.id == id })).first
        return includingDeleted || reminder?.deletedAt == nil ? reminder : nil
    }

    /// As `findNote`.
    func findItem(_ id: UUID, includingDeleted: Bool = false) -> ReGlassItem? {
        let item = fetch(FetchDescriptor<ReGlassItem>(predicate: #Predicate { $0.id == id })).first
        return includingDeleted || item?.deletedAt == nil ? item : nil
    }

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            log("Library: a read failed (\(type(of: error)))")
            return []
        }
    }

    /// Saves and posts `didChange`. `what` goes to the activity log only if saving fails: a state, never content.
    func save(_ what: String) {
        do {
            try context.save()
        } catch {
            log("Library: \(what), but saving failed (\(type(of: error)))")
        }
        changed()
    }

    func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Trimmed, or nil when empty.
    static func clean(_ text: String?) -> String? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Private

    private static func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: protection])
        try manager.setAttributes([.protectionKey: protection], ofItemAtPath: directory.path)
    }

    /// The library's store file, syncing through `cloudKitDatabase` (`.none`: this iPhone only).
    private static func openStore(_ schema: Schema,
                                  cloudKitDatabase: ModelConfiguration.CloudKitDatabase) throws -> ModelContainer {
        let configuration = ModelConfiguration("Library", schema: schema,
                                               url: directory.appendingPathComponent("Library.store"),
                                               cloudKitDatabase: cloudKitDatabase)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// The store, its journal and shared memory files. New ones inherit the folder's class; this covers older ones.
    private static func protectFiles() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? manager.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
        }
    }
}
