import EventKit
import Foundation
import ReGlassAssistant

/// What the EventKit `add_to_list` asked for, already checked by the tool.
struct AddRemindersRequest: Sendable {
    var titles: [String]
    var list: String?
    var due: ReminderDue?
    /// EventKit's scale: 1 high, 5 medium, 9 low.
    var priority: Int?
    var note: String?
}

enum ReminderScope: String, Sendable, CaseIterable {
    case open, today, overdue, upcoming
    case completedToday = "completed_today"
}

struct ListRemindersRequest: Sendable {
    var list: String?
    var scope: ReminderScope?
    var limit: Int
}

struct CompleteReminderRequest: Sendable {
    var title: String
    var list: String?
    var undo: Bool
}

/// The owner's lists for the settings screen.
struct ReminderListsSnapshot: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let writable: Bool
    }

    var lists: [Entry]
    var appDefaultID: String?
    var appDefaultTitle: String?
}

/// ReGlass's door to Apple Reminders. One `EKEventStore`, used only from this actor (it isn't `Sendable`). Every call
/// re-reads the lists, so changes made in the Reminders app, on another device or by Siri are always seen.
///
/// Unused for now: the Lists connector's tools act on ReGlass's own lists (Connectors/Lists/), and nothing is
/// imported. Kept, with `ReminderMatching.swift`, for a later link of a category to an Apple Reminders list.
///
/// Reminders data is "protected until first unlock": this works with the iPhone locked in a pocket, but not after a
/// restart until it has been unlocked once.
actor ReminderStore {
    /// The list chosen in the connector's settings (a calendar identifier). Empty: follow the Reminders app.
    static let defaultListKey = "reglass.reminders.defaultList"

    enum Access: Sendable, Equatable {
        case allowed, notAsked, denied
    }

    /// Cheap: no store needed.
    static var access: Access {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return .allowed }
        // Reminders has no write-only level; treat a stray one as not asked yet.
        if status == .notDetermined || status == .writeOnly { return .notAsked }
        return .denied
    }

    private let log: @Sendable (String) -> Void
    private var eventStore: EKEventStore?

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Made on first use: creating a store is slow, and most launches never touch Reminders.
    private var store: EKEventStore {
        if let eventStore { return eventStore }
        let fresh = EKEventStore()
        eventStore = fresh
        return fresh
    }

    // MARK: Access

    /// Shows iOS's prompt (ReGlass must be in the foreground). True when full access was granted.
    func requestAccess() async -> Bool {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            log("Reminders: access request failed (code \((error as NSError).code))")
            granted = false
        }
        // A store made before access was granted can stay empty; start a fresh one.
        if granted { eventStore = nil }
        return granted
    }

    private enum Gate {
        case open([EKCalendar])
        case closed(ToolResult)
    }

    private func gate(_ what: String) -> Gate {
        switch Self.access {
        case .notAsked:
            log("Reminders: \(what) refused, access not allowed yet")
            return .closed(.failure("ReGlass doesn't have access to Reminders yet. The owner can allow it once in the ReGlass app on their iPhone: Settings, Connectors, Reminders, Allow access."))
        case .denied:
            log("Reminders: \(what) refused, access turned off")
            return .closed(.failure("Reminders access is turned off for ReGlass. The owner can turn it on in the iPhone's Settings app, under ReGlass."))
        case .allowed:
            break
        }
        let calendars = store.calendars(for: .reminder)
        if calendars.isEmpty {
            // Most likely the iPhone hasn't been unlocked since it restarted. Try a fresh store next time.
            eventStore = nil
            log("Reminders: \(what) found no lists")
            return .closed(.failure("ReGlass can't see any Reminders lists right now. If the iPhone restarted, it needs to be unlocked once first; otherwise there are no lists in the Reminders app yet."))
        }
        return .open(calendars)
    }

    // MARK: Lists

    /// The list new reminders go to: the one chosen in ReGlass, else the Reminders app's default, else any list ReGlass
    /// may write to.
    private func defaultList(in calendars: [EKCalendar]) -> EKCalendar? {
        let writable = calendars.filter(\.allowsContentModifications)
        if let chosen = UserDefaults.standard.string(forKey: Self.defaultListKey), !chosen.isEmpty,
           let list = writable.first(where: { $0.calendarIdentifier == chosen }) {
            return list
        }
        if let system = store.defaultCalendarForNewReminders(), system.allowsContentModifications,
           writable.contains(where: { $0.calendarIdentifier == system.calendarIdentifier }) {
            return system
        }
        return writable.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.first
    }

    private func entries(_ calendars: [EKCalendar]) -> [ReminderListEntry] {
        calendars.map { ReminderListEntry(id: $0.calendarIdentifier, title: $0.title) }
    }

    private func names(_ calendars: [EKCalendar]) -> JSONValue {
        .array(calendars.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { .string($0) })
    }

    /// For the settings screen. Nil without access.
    func snapshot() -> ReminderListsSnapshot? {
        guard Self.access == .allowed else { return nil }
        let calendars = store.calendars(for: .reminder)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let system = store.defaultCalendarForNewReminders()
        return ReminderListsSnapshot(
            lists: calendars.map { .init(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications) },
            appDefaultID: system?.calendarIdentifier,
            appDefaultTitle: system?.title)
    }

    // MARK: Fetching

    /// EventKit hands back non-Sendable objects on its own queue; they're only used on this actor afterwards.
    private final class Batch: @unchecked Sendable {
        let reminders: [EKReminder]
        init(_ reminders: [EKReminder]) { self.reminders = reminders }
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        let batch: Batch = await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: Batch(reminders ?? []))
            }
        }
        return batch.reminders
    }

    private func openReminders(in calendars: [EKCalendar]?) async -> [EKReminder] {
        await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
    }

    private func completedReminders(since start: Date, until end: Date, in calendars: [EKCalendar]?) async -> [EKReminder] {
        await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: calendars))
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        return "\(ms) ms"
    }

    private static func title(of reminder: EKReminder) -> String {
        (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Adding

    func add(_ request: AddRemindersRequest, context: ToolContext) async -> ToolResult {
        let started = ContinuousClock.now
        let calendars: [EKCalendar]
        switch gate("add") {
        case .closed(let result): return result
        case .open(let found): calendars = found
        }
        let writable = calendars.filter(\.allowsContentModifications)
        guard let fallback = defaultList(in: calendars) else {
            log("Reminders: add refused, no list ReGlass can write to")
            return .failure("None of the owner's Reminders lists can be changed from ReGlass. Create a list in the Reminders app first.")
        }

        var target = fallback
        var how = "default"
        var facts: [String: JSONValue] = [:]
        if let spoken = request.list {
            switch ReminderListMatcher.match(spoken, among: entries(writable), defaultID: fallback.calendarIdentifier) {
            case .found(let id, let kind):
                target = writable.first { $0.calendarIdentifier == id } ?? fallback
                how = kind
                if kind != "exact" { facts["asked_list"] = .string(spoken) }
            case .ambiguous(let ids):
                let choices = writable.filter { ids.contains($0.calendarIdentifier) }
                log("Reminders: add paused, \(choices.count) lists could match")
                return .success(ReminderText.json([
                    "added": [],
                    "needs_choice": "More than one list could match. Nothing was added. Ask which list, then call again with its exact name.",
                    "asked_list": .string(spoken),
                    "candidates": names(choices),
                ]), action: ToolAction(title: "Asked which list", detail: ReminderText.englishList(choices.map(\.title))))
            case .none:
                // A matching list ReGlass may not write to (a read-only shared list) is worth saying.
                if case .found(let id, _) = ReminderListMatcher.match(spoken, among: entries(calendars), defaultID: nil),
                   let readOnly = calendars.first(where: { $0.calendarIdentifier == id }) {
                    log("Reminders: add refused, the list is read-only")
                    return .failure("The list \(readOnly.title) can't be changed from ReGlass (it's read-only), so nothing was added.",
                                    action: ToolAction(title: "Couldn't add to \(readOnly.title)", detail: "That list is read-only"))
                }
                facts["asked_list"] = .string(spoken)
                facts["list_note"] = .string("No list matches \"\(spoken)\", so the default list \(fallback.title) was used. Tell the owner.")
                facts["other_lists"] = names(writable.filter { $0.calendarIdentifier != fallback.calendarIdentifier })
                how = "none, used default"
            }
        }

        // Without a due date, don't add something that's already open on the list ("Milk" twice).
        var fresh = request.titles
        var already: [String] = []
        if request.due == nil {
            let open = await openReminders(in: [target]).map(Self.title)
            fresh = []
            for title in request.titles {
                if open.contains(where: { ReminderTitleMatcher.sameTitle($0, title) })
                    || fresh.contains(where: { ReminderTitleMatcher.sameTitle($0, title) }) {
                    already.append(title)
                } else {
                    fresh.append(title)
                }
            }
        }

        if Task.isCancelled { return .failure("Cancelled before anything was added.") }

        let dueDate = request.due.flatMap { $0.date(in: context.timeZone) }
        if !fresh.isEmpty {
            do {
                for title in fresh {
                    let reminder = EKReminder(eventStore: store)
                    reminder.title = title
                    reminder.calendar = target
                    if let due = request.due {
                        reminder.dueDateComponents = due.components(in: context.timeZone)
                        // The alarm is what makes the iPhone notify; the due date alone may stay silent.
                        if due.hasTime, let dueDate { reminder.addAlarm(EKAlarm(absoluteDate: dueDate)) }
                    }
                    if let priority = request.priority { reminder.priority = priority }
                    if let note = request.note { reminder.notes = note }
                    try store.save(reminder, commit: false)
                }
                try store.commit()
            } catch {
                store.reset()
                log("Reminders: add failed (code \((error as NSError).code)) after \(Self.elapsed(since: started))")
                return .failure("Reminders didn't save that. Nothing was added; try again in a moment.",
                                action: ToolAction(title: "Couldn't add to \(target.title)", detail: "Reminders didn't save it"))
            }
        }

        facts["list"] = .string(target.title)
        facts["added"] = .array(fresh.map { .string($0) })
        if !already.isEmpty { facts["already_on_list"] = .array(already.map { .string($0) }) }
        if let due = request.due, let dueDate {
            facts["due"] = .string(ReminderDates.forClaude(dueDate, allDay: !due.hasTime, now: context.date, timeZone: context.timeZone))
            facts["alert"] = .bool(due.hasTime && !fresh.isEmpty)
        }
        log("Reminders: added \(fresh.count), \(already.count) already there, list \(how)"
            + (request.due == nil ? "" : (request.due?.hasTime == true ? ", due with alert" : ", due all day"))
            + " (\(Self.elapsed(since: started)))")

        // The line in Chats: `Added “Call the dentist”` · Reminders · tomorrow 09:00.
        let title: String
        switch fresh.count {
        case 0: title = "Already on \(target.title)"
        case 1: title = "Added “\(fresh[0])”"
        case 2...3: title = "Added \(ReminderText.englishList(fresh))"
        default: title = "Added \(fresh.count) items"
        }
        var detail = [target.title]
        if let due = request.due, let dueDate {
            detail.append(ReminderDates.forChats(dueDate, allDay: !due.hasTime, now: context.date, timeZone: context.timeZone))
        }
        if fresh.count > 1 { detail.append("\(fresh.count) items") }
        if fresh.isEmpty { detail.append(ReminderText.englishList(already)) }
        return .success(ReminderText.json(.object(facts)), action: ToolAction(title: title, detail: detail.joined(separator: " · ")))
    }

    // MARK: Reading

    private struct Item {
        let title: String
        let list: String
        let due: Date?
        let allDay: Bool
        let overdue: Bool
        let dueToday: Bool
        let priority: Int
        let created: Date
    }

    func list(_ request: ListRemindersRequest, context: ToolContext) async -> ToolResult {
        let started = ContinuousClock.now
        let calendars: [EKCalendar]
        switch gate("read") {
        case .closed(let result): return result
        case .open(let found): calendars = found
        }

        var chosen: EKCalendar?
        var facts: [String: JSONValue] = [:]
        if let spoken = request.list {
            switch ReminderListMatcher.match(spoken, among: entries(calendars), defaultID: defaultList(in: calendars)?.calendarIdentifier) {
            case .found(let id, let kind):
                chosen = calendars.first { $0.calendarIdentifier == id }
                if kind != "exact" { facts["asked_list"] = .string(spoken) }
            case .ambiguous(let ids):
                let choices = calendars.filter { ids.contains($0.calendarIdentifier) }
                log("Reminders: read paused, \(choices.count) lists could match")
                return .success(ReminderText.json([
                    "needs_choice": "More than one list could match. Ask which list, then call again with its exact name.",
                    "asked_list": .string(spoken),
                    "candidates": names(choices),
                ]), action: ToolAction(title: "Asked which list", detail: ReminderText.englishList(choices.map(\.title))))
            case .none:
                log("Reminders: read found no matching list")
                return .failure(ReminderText.json([
                    "error": "no_such_list",
                    "asked_list": .string(spoken),
                    "lists": names(calendars),
                ]), action: ToolAction(title: "Couldn't find that list", detail: ReminderText.englishList(calendars.map(\.title).sorted())))
            }
        }

        let scope = request.scope ?? (chosen == nil ? .today : .open)
        let now = context.date, zone = context.timeZone
        let raw: [EKReminder]
        if scope == .completedToday {
            let start = ReminderDue.calendar(zone).startOfDay(for: now)
            raw = await completedReminders(since: start, until: now.addingTimeInterval(60), in: chosen.map { [$0] })
        } else {
            raw = await openReminders(in: chosen.map { [$0] })
        }
        if Task.isCancelled { return .failure("Cancelled.") }

        var items: [Item] = raw.compactMap { reminder in
            let title = Self.title(of: reminder)
            guard !title.isEmpty else { return nil }
            let due = ReminderDates.resolve(reminder.dueDateComponents, timeZone: zone)
            let overdue = scope != .completedToday && due.map { ReminderDates.isOverdue($0.date, allDay: $0.allDay, now: now, timeZone: zone) } == true
            let dueToday = due.map { ReminderDates.dayOffset($0.date, now: now, timeZone: zone) == 0 } == true
            return Item(title: title, list: reminder.calendar?.title ?? "", due: due?.date, allDay: due?.allDay ?? false,
                        overdue: overdue, dueToday: dueToday, priority: reminder.priority,
                        created: reminder.creationDate ?? .distantPast)
        }

        switch scope {
        case .open, .completedToday:
            break
        case .today:
            items = items.filter { $0.overdue || $0.dueToday }
        case .overdue:
            items = items.filter(\.overdue)
        case .upcoming:
            items = items.filter { item in
                guard let due = item.due, !item.overdue else { return false }
                return ReminderDates.dayOffset(due, now: now, timeZone: zone) < 7
            }
        }

        // Most urgent first: overdue, due today, high priority, then dated by time, then oldest first.
        func rank(_ item: Item) -> Int {
            if item.overdue { return 0 }
            if item.dueToday { return 1 }
            if (1...4).contains(item.priority) { return 2 }
            return item.due == nil ? 4 : 3
        }
        items.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if let da = a.due, let db = b.due, da != db { return da < db }
            if a.created != b.created { return a.created < b.created }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }

        let limit = min(max(request.limit, 1), 30)
        let acrossLists = chosen == nil
        let shown = items.prefix(limit).map { item -> JSONValue in
            var entry: [String: JSONValue] = ["title": .string(item.title)]
            if let due = item.due {
                entry["due"] = .string(ReminderDates.forClaude(due, allDay: item.allDay, now: now, timeZone: zone))
            }
            if item.overdue { entry["overdue"] = true }
            switch item.priority {
            case 1...4: entry["priority"] = "high"
            case 5: entry["priority"] = "medium"
            case 6...9: entry["priority"] = "low"
            default: break
            }
            if acrossLists { entry["list"] = .string(item.list) }
            return .object(entry)
        }

        facts["list"] = .string(chosen?.title ?? "all lists")
        facts["scope"] = .string(scope.rawValue)
        facts["total"] = .int(items.count)
        facts["items"] = .array(shown)
        if items.count > shown.count { facts["not_shown"] = .int(items.count - shown.count) }
        if scope != .completedToday && scope != .open { facts["overdue_count"] = .int(items.filter(\.overdue).count) }
        log("Reminders: read \(scope.rawValue), \(shown.count) of \(items.count) (\(Self.elapsed(since: started)))")

        let actionTitle: String
        let detail: String
        switch scope {
        case .open:
            actionTitle = "Read \(chosen?.title ?? "your lists")"
            detail = items.isEmpty ? "Nothing open" : "\(items.count) open"
        case .today:
            actionTitle = "Checked today’s list items" + (chosen.map { " on \($0.title)" } ?? "")
            let late = items.filter(\.overdue).count
            detail = items.isEmpty ? "Nothing due" : "\(items.count - late) due today" + (late > 0 ? ", \(late) overdue" : "")
        case .overdue:
            actionTitle = "Checked overdue list items"
            detail = items.isEmpty ? "Nothing overdue" : "\(items.count) overdue"
        case .upcoming:
            actionTitle = "Checked the week ahead"
            detail = items.isEmpty ? "Nothing coming up" : "\(items.count) coming up"
        case .completedToday:
            actionTitle = "Checked what’s done today"
            detail = items.isEmpty ? "Nothing ticked off yet" : "\(items.count) ticked off"
        }
        return .success(ReminderText.json(.object(facts)), action: ToolAction(title: actionTitle, detail: detail))
    }

    // MARK: Ticking off

    func complete(_ request: CompleteReminderRequest, context: ToolContext) async -> ToolResult {
        let started = ContinuousClock.now
        let calendars: [EKCalendar]
        switch gate(request.undo ? "untick" : "tick off") {
        case .closed(let result): return result
        case .open(let found): calendars = found
        }
        let writable = calendars.filter(\.allowsContentModifications)

        var scoped: EKCalendar?
        var facts: [String: JSONValue] = [:]
        if let spoken = request.list {
            switch ReminderListMatcher.match(spoken, among: entries(writable), defaultID: defaultList(in: calendars)?.calendarIdentifier) {
            case .found(let id, _):
                scoped = writable.first { $0.calendarIdentifier == id }
            case .ambiguous(let ids):
                let choices = writable.filter { ids.contains($0.calendarIdentifier) }
                log("Reminders: tick off paused, \(choices.count) lists could match")
                return .success(ReminderText.json([
                    "changed": false,
                    "needs_choice": "More than one list could match. Nothing was changed. Ask which list, then call again with its exact name.",
                    "asked_list": .string(spoken),
                    "candidates": names(choices),
                ]), action: ToolAction(title: "Asked which list", detail: ReminderText.englishList(choices.map(\.title))))
            case .none:
                facts["list_note"] = .string("No list matches \"\(spoken)\", so every list was searched.")
            }
        }

        let now = context.date
        func candidates(in lists: [EKCalendar]) async -> [EKReminder] {
            if request.undo {
                return await completedReminders(since: now.addingTimeInterval(-48 * 3600), until: now.addingTimeInterval(60), in: lists)
            }
            return await openReminders(in: lists)
        }
        func best(_ reminders: [EKReminder]) -> (score: Int, matches: [EKReminder]) {
            var top = 0
            var matches: [EKReminder] = []
            for reminder in reminders {
                let score = ReminderTitleMatcher.score(query: request.title, title: Self.title(of: reminder))
                if score > top { top = score; matches = [reminder] } else if score == top, score > 0 { matches.append(reminder) }
            }
            return top >= 60 ? (top, matches) : (0, [])
        }

        var pool = await candidates(in: scoped.map { [$0] } ?? writable)
        var found = best(pool)
        if found.matches.isEmpty, let scoped {
            // Not on the named list: look everywhere, and say so.
            let everywhere = await candidates(in: writable)
            let wider = best(everywhere)
            if !wider.matches.isEmpty {
                facts["list_note"] = .string("Not found on \(scoped.title); found on another list.")
                pool = everywhere
                found = wider
            }
        }
        if Task.isCancelled { return .failure("Cancelled before anything was changed.") }

        guard !found.matches.isEmpty else {
            log("Reminders: \(request.undo ? "untick" : "tick off") found no match (\(Self.elapsed(since: started)))")
            facts["error"] = "no_match"
            facts["asked"] = .string(request.title)
            facts["searched"] = .string(request.undo ? "items completed in the last two days" : "open items")
            if let scoped {
                facts["list"] = .string(scoped.title)
                let titles = pool.prefix(10).map(Self.title).filter { !$0.isEmpty }
                facts[request.undo ? "recently_completed" : "open_items"] = .array(titles.map { .string($0) })
            }
            return .failure(ReminderText.json(.object(facts)),
                            action: ToolAction(title: "Couldn’t find “\(request.title)”", detail: scoped?.title ?? "Reminders"))
        }

        var matches = found.matches
        // The same title on the same list twice ("Milk", "Milk"): tick off one, the oldest (or the latest done for undo).
        let first = matches[0]
        let identical = matches.allSatisfy {
            $0.calendar?.calendarIdentifier == first.calendar?.calendarIdentifier
                && ReminderTitleMatcher.sameTitle(Self.title(of: $0), Self.title(of: first))
        }
        if matches.count > 1 && !identical {
            log("Reminders: \(request.undo ? "untick" : "tick off") paused, \(matches.count) matches (\(Self.elapsed(since: started)))")
            facts["changed"] = false
            facts["needs_choice"] = "More than one reminder could match. Nothing was changed. Ask which one, then call again with its exact title or its list."
            facts["candidates"] = .array(matches.prefix(6).map { .object(["title": .string(Self.title(of: $0)), "list": .string($0.calendar?.title ?? "")]) })
            return .success(ReminderText.json(.object(facts)),
                            action: ToolAction(title: "Asked which “\(request.title)”", detail: "\(matches.count) matches"))
        }
        if request.undo {
            matches.sort { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        } else {
            matches.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
        let target = matches[0]
        let title = Self.title(of: target)
        let listTitle = target.calendar?.title ?? ""

        target.isCompleted = !request.undo
        do {
            try store.save(target, commit: true)
        } catch {
            store.reset()
            log("Reminders: \(request.undo ? "untick" : "tick off") failed (code \((error as NSError).code))")
            return .failure("Reminders didn't save that change. Nothing changed; try again in a moment.")
        }

        facts[request.undo ? "unticked" : "completed"] = .string(title)
        facts["list"] = .string(listTitle)
        if matches.count > 1 { facts["same_title_still_\(request.undo ? "done" : "open")"] = .int(matches.count - 1) }
        log("Reminders: \(request.undo ? "unticked" : "ticked off") 1 (\(Self.elapsed(since: started)))")
        return .success(ReminderText.json(.object(facts)),
                        action: ToolAction(title: request.undo ? "Unticked “\(title)”" : "Ticked off “\(title)”", detail: listTitle))
    }

    // MARK: The lists themselves

    func listLists(context: ToolContext) async -> ToolResult {
        let started = ContinuousClock.now
        let calendars: [EKCalendar]
        switch gate("lists") {
        case .closed(let result): return result
        case .open(let found): calendars = found
        }
        let open = await openReminders(in: nil)
        var counts: [String: Int] = [:]
        for reminder in open {
            if let id = reminder.calendar?.calendarIdentifier { counts[id, default: 0] += 1 }
        }
        let sorted = calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let lists: [JSONValue] = sorted.map { list in
            var entry: [String: JSONValue] = ["name": .string(list.title), "open": .int(counts[list.calendarIdentifier] ?? 0)]
            if !list.allowsContentModifications { entry["read_only"] = true }
            return .object(entry)
        }
        var facts: [String: JSONValue] = ["lists": .array(lists)]
        if let fallback = defaultList(in: calendars) { facts["default"] = .string(fallback.title) }
        log("Reminders: listed \(calendars.count) lists (\(Self.elapsed(since: started)))")
        return .success(ReminderText.json(.object(facts)),
                        action: ToolAction(title: "Checked your lists", detail: "\(calendars.count) list\(calendars.count == 1 ? "" : "s")"))
    }
}
