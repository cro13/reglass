import EventKit
import Foundation
import UIKit

// Apple Calendar through EventKit. Calendars synced into iOS Calendar (Google, Exchange and others) are included. Calendar data is "Protected Until First User Authentication", so everything here works with the
// iPhone locked once it has been unlocked one time since boot.

/// One event, copied out of EventKit so it can leave the store's actor. Declined and cancelled events never get here.
struct CalEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The written place, without links. Nil for none or for a video call link.
    let place: String?
    let videoCall: Bool
    let calendarTitle: String
    /// The owner hasn't answered the invitation yet.
    let invitePending: Bool
    /// False for events marked "free" in Calendar: they don't take up time.
    let blocksTime: Bool
    /// The event's own zone when it has one (a call booked in New York time).
    let timeZone: TimeZone?
}

/// One calendar, for Settings.
struct CalCalendar: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    /// The account it lives in: "iCloud", the Google address, "Subscribed Calendars".
    let source: String
    let red: Double
    let green: Double
    let blue: Double
    /// ReGlass can add events to it (shared calendars you can only view can't).
    let writable: Bool
}

/// Which calendars ReGlass reads and where new events go. Remembered on this iPhone. Calendars are stored as the
/// ones switched *off*, so a calendar added later is read straight away.
enum CalPreferences {
    private static let hiddenKey = "reglass.calendar.hiddenCalendars"
    private static let defaultKey = "reglass.calendar.newEventsCalendar"

    static var hiddenIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey) }
    }

    /// Nil: the iPhone's own default calendar (Settings → Apps → Calendar → Default Calendar).
    static var defaultCalendarID: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey) }
    }
}

/// Why a calendar call failed, with one plain sentence Claude can say.
enum CalProblem: Error, Sendable {
    case noAccess(EKAuthorizationStatus)
    case notReadable
    case allHidden
    case noWritableCalendar
    case noSuchCalendar(String, [String])
    case notReadBack
    case noAnswerYet
    case saveFailed

    var sentence: String {
        switch self {
        case .noAccess(let status):
            switch status {
            case .denied, .restricted:
                return "Calendar access is turned off for ReGlass in the iPhone's Settings app."
            default:
                return "ReGlass can't see the calendar yet. Open ReGlass on the iPhone, go to Settings, Connectors, Calendar, and allow access."
            }
        case .notReadable:
            return "The calendar can't be read right now. If the iPhone restarted, it needs to be unlocked once."
        case .allHidden:
            return "Every calendar is switched off for ReGlass in Settings, Connectors, Calendar."
        case .noWritableCalendar:
            return "There's no calendar ReGlass can add events to."
        case .noSuchCalendar(let name, let names):
            let list = names.isEmpty ? "none" : names.joined(separator: ", ")
            return "There's no calendar called \"\(name)\" that ReGlass can add to. Calendars ReGlass can add to: \(list)."
        case .notReadBack:
            return "Not saved: these details haven't been read back yet. Call add_event with confirmed=false first, read the result back and wait for a clear yes."
        case .noAnswerYet:
            return "Not saved: the owner hasn't answered yet. Read the details back, ask, and call add_event with confirmed=true only after they say yes in their next reply."
        case .saveFailed:
            return "The iPhone couldn't save the event."
        }
    }

    /// For the activity log: a kind, never content.
    var logKind: String {
        switch self {
        case .noAccess: return "no access"
        case .notReadable: return "store not readable"
        case .allHidden: return "all calendars off"
        case .noWritableCalendar: return "no writable calendar"
        case .noSuchCalendar: return "calendar not found"
        case .notReadBack: return "add refused, not read back"
        case .noAnswerYet: return "add refused, no answer yet"
        case .saveFailed: return "save failed"
        }
    }
}

/// A new event, already resolved to absolute times.
struct CalDraft: Sendable {
    var title: String
    var start: Date
    /// Timed events: the end. All-day events: the start of the last day.
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var calendarName: String?
    var timeZone: TimeZone
}

struct CalAddOutcome: Sendable {
    let calendarTitle: String
    let clashes: [CalEvent]
    let saved: Bool
    /// The same event was saved moments ago; it wasn't saved twice.
    let duplicate: Bool
}

/// Owns ReGlass's EventKit store for events (the Reminders connector has its own). `EKEventStore` isn't Sendable, so
/// it lives in this actor and only plain values come out.
actor CalStore {
    /// Created on first use, and again if it can't see any calendars: a store opened before the first unlock after
    /// a restart (the app can be woken in the background then) may stay empty.
    private var storage: EKEventStore?
    /// Read-backs (`confirmed: false`) a save must match: when each was made, and the turn that made it (a save in the
    /// same turn is refused, so the owner's yes must come in a reply of its own). Several at once: "add lunch and gym".
    private var previews: [String: (at: Date, turn: Date)] = [:]
    /// Recent saves, so a repeated confirm doesn't add the event twice.
    private var saves: [String: Date] = [:]

    private static let previewLifetime: TimeInterval = 5 * 60
    private static let duplicateWindow: TimeInterval = 3 * 60

    nonisolated static var access: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    private var store: EKEventStore {
        if let storage { return storage }
        let fresh = EKEventStore()
        storage = fresh
        return fresh
    }

    // MARK: Access

    /// Shows iOS's prompt (ReGlass in the foreground). True once full access is granted.
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { storage = nil }
        return granted && Self.access == .fullAccess
    }

    /// Every event calendar, or a problem. Retries once with a fresh store when none show up.
    private func allCalendars() -> Result<[EKCalendar], CalProblem> {
        let status = Self.access
        guard status == .fullAccess else { return .failure(.noAccess(status)) }
        var calendars = store.calendars(for: .event)
        if calendars.isEmpty {
            storage = nil
            calendars = store.calendars(for: .event)
        }
        return calendars.isEmpty ? .failure(.notReadable) : .success(calendars)
    }

    // MARK: Reading

    /// The calendars for Settings, sorted by account then name, plus the iPhone's own default for new events.
    func calendarSnapshot() -> (calendars: [CalCalendar], systemDefaultID: String?) {
        guard case .success(let calendars) = allCalendars() else { return ([], nil) }
        let mapped = calendars.map { Self.snapshot(of: $0) }.sorted(by: Self.inSettingsOrder)
        return (mapped, store.defaultCalendarForNewEvents?.calendarIdentifier)
    }

    private static func snapshot(of calendar: EKCalendar) -> CalCalendar {
        var red: CGFloat = 0.5
        var green: CGFloat = 0.5
        var blue: CGFloat = 0.5
        var alpha: CGFloat = 1
        if let color = calendar.cgColor {
            UIColor(cgColor: color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        let source: String = calendar.source?.title ?? ""
        return CalCalendar(id: calendar.calendarIdentifier, title: calendar.title, source: source,
                           red: Double(red), green: Double(green), blue: Double(blue),
                           writable: calendar.allowsContentModifications)
    }

    /// By account, then by name.
    private static func inSettingsOrder(_ a: CalCalendar, _ b: CalCalendar) -> Bool {
        if a.source != b.source { return a.source.localizedStandardCompare(b.source) == .orderedAscending }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// Events overlapping `start..<end` on the calendars ReGlass may read, sorted by start. Declined and cancelled
    /// events are left out; the same meeting on two calendars counts once.
    func events(from start: Date, to end: Date) -> Result<[CalEvent], CalProblem> {
        let calendars: [EKCalendar]
        switch allCalendars() {
        case .failure(let problem): return .failure(problem)
        case .success(let all): calendars = all
        }
        let hidden = CalPreferences.hiddenIDs
        let readable = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !readable.isEmpty else { return .failure(.allHidden) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: readable)
        var seen: Set<String> = []
        var result: [CalEvent] = []
        for event in store.events(matching: predicate) {
            guard event.status != .canceled,
                  let eventStart = event.startDate, let eventEnd = event.endDate else { continue }
            let me = event.attendees?.first { $0.isCurrentUser }
            if me?.participantStatus == .declined { continue }
            let title = Self.clean(event.title, limit: 120) ?? "Untitled event"
            let key = "\(title.lowercased())|\(eventStart.timeIntervalSince1970)|\(eventEnd.timeIntervalSince1970)|\(event.isAllDay)"
            guard seen.insert(key).inserted else { continue }
            let (place, videoCall) = Self.place(location: event.location, url: event.url)
            result.append(CalEvent(title: title, start: eventStart, end: eventEnd, isAllDay: event.isAllDay,
                                   place: place, videoCall: videoCall,
                                   calendarTitle: event.calendar?.title ?? "",
                                   invitePending: me?.participantStatus == .pending,
                                   blocksTime: event.availability != .free,
                                   timeZone: event.isAllDay ? nil : event.timeZone))
        }
        return .success(result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            return $0.end < $1.end
        })
    }

    // MARK: Adding

    /// `confirmed: false` resolves the calendar, finds clashes and remembers the read-back; nothing is saved.
    /// `confirmed: true` saves, but only when it matches a read-back from the last few minutes made in an earlier
    /// turn, so a save always follows a question the owner heard and answered. `turn` is the request's turn date
    /// (`ToolContext.date`), the same for every call in one turn and new for each reply.
    func add(_ draft: CalDraft, confirmed: Bool, turn: Date) -> Result<CalAddOutcome, CalProblem> {
        if case .failure(let problem) = allCalendars() { return .failure(problem) }
        let calendar: EKCalendar
        switch resolveCalendar(named: draft.calendarName) {
        case .failure(let problem): return .failure(problem)
        case .success(let found): calendar = found
        }

        let key = [String(draft.start.timeIntervalSince1970), String(draft.end.timeIntervalSince1970), String(draft.allDay),
                   calendar.calendarIdentifier, Self.matchText(draft.title), Self.matchText(draft.location ?? "")]
            .joined(separator: "|")
        let clashes: [CalEvent]
        if draft.allDay {
            clashes = []
        } else {
            let found = (try? events(from: draft.start, to: draft.end).get()) ?? []
            clashes = found.filter { !$0.isAllDay && $0.blocksTime && $0.start < draft.end && $0.end > draft.start }
        }
        let now = Date()
        previews = previews.filter { now.timeIntervalSince($0.value.at) < Self.previewLifetime }
        saves = saves.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }

        if !confirmed {
            previews[key] = (now, turn)
            return .success(CalAddOutcome(calendarTitle: calendar.title, clashes: clashes, saved: false, duplicate: false))
        }
        if saves[key] != nil {
            return .success(CalAddOutcome(calendarTitle: calendar.title, clashes: clashes, saved: true, duplicate: true))
        }
        guard let preview = previews[key] else { return .failure(.notReadBack) }
        guard preview.turn != turn else { return .failure(.noAnswerYet) }

        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.calendar = calendar
        event.isAllDay = draft.allDay
        event.startDate = draft.start
        event.endDate = draft.end
        // All-day events float (they stay on their day wherever you are); timed ones are pinned to the zone.
        event.timeZone = draft.allDay ? nil : draft.timeZone
        event.location = draft.location
        event.notes = draft.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure(.saveFailed)
        }
        previews[key] = nil
        saves[key] = now
        return .success(CalAddOutcome(calendarTitle: calendar.title, clashes: clashes, saved: true, duplicate: false))
    }

    /// The calendar the owner named, else the one chosen in Settings, else the iPhone's default.
    private func resolveCalendar(named name: String?) -> Result<EKCalendar, CalProblem> {
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        if let name, !name.isEmpty {
            let wanted = Self.normalised(name)
            let exact = writable.first { Self.normalised($0.title) == wanted }
            let loose = writable.first {
                let title = Self.normalised($0.title)
                return title.contains(wanted) || wanted.contains(title)
            }
            if let found = exact ?? loose { return .success(found) }
            return .failure(.noSuchCalendar(name, writable.map(\.title)))
        }
        if let id = CalPreferences.defaultCalendarID, let chosen = store.calendar(withIdentifier: id),
           chosen.allowsContentModifications {
            return .success(chosen)
        }
        if let system = store.defaultCalendarForNewEvents, system.allowsContentModifications { return .success(system) }
        if let first = writable.first { return .success(first) }
        return .failure(.noWritableCalendar)
    }

    // MARK: Text

    /// "My work calendar" and "Work" match.
    /// Title and place as compared between a read-back and its save: case and spacing don't matter.
    private static func matchText(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalised(_ text: String) -> String {
        let filler: Set<String> = ["my", "the", "calendar", "cal"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
        return words.isEmpty ? text.lowercased().trimmingCharacters(in: .whitespaces) : words.joined(separator: " ")
    }

    /// One line, trimmed and capped. Nil when empty.
    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// A place worth saying, and whether the event is a video call. Links are never passed on.
    private static func place(location: String?, url: URL?) -> (String?, Bool) {
        let markers = ["zoom.us", "meet.google", "teams.microsoft", "teams.live", "webex", "facetime", "whereby"]
        let haystack = ((location ?? "") + " " + (url?.absoluteString ?? "")).lowercased()
        let videoCall = markers.contains { haystack.contains($0) }
        guard let line = clean(location, limit: 100) else { return (nil, videoCall) }
        if line.contains("://") || line.lowercased().hasPrefix("www.") { return (nil, true) }
        return (line, videoCall)
    }
}

/// Activity log lines for Calendar: counts and timings only, never titles, places or calendar names.
enum CalLog {
    static func add(_ text: String) {
        Task { @MainActor in GlassesController.shared.log.add("Calendar: " + text) }
    }
}
