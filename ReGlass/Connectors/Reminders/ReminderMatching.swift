import Foundation
import ReGlassAssistant

// Pure helpers for the Reminders connector: folding spoken words, finding a list by a loosely spoken name, scoring
// reminder titles against what was said, and reading and writing due dates. No EventKit here.

// MARK: Folding

enum ReminderText {
    /// Lower case, no accents ("Einkäufe" → "einkaufe", "cumpărături" → "cumparaturi"), punctuation and emoji turned
    /// into spaces, single spaces. "To-do" and "to do" become "todo".
    static func fold(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        let words = cleaned.split(separator: " ").map(String.init)
        var joined: [String] = []
        var index = 0
        while index < words.count {
            if words[index] == "to", index + 1 < words.count, words[index + 1] == "do" {
                joined.append("todo")
                index += 2
            } else {
                joined.append(words[index])
                index += 1
            }
        }
        return joined.joined(separator: " ")
    }

    /// Folded words without filler. Falls back to every word when nothing else is left (a list called "List").
    static func words(_ text: String, dropping filler: Set<String>) -> [String] {
        let all = fold(text).split(separator: " ").map(String.init)
        let kept = all.filter { !filler.contains($0) }
        return kept.isEmpty ? all : kept
    }

    /// "Milk", "Milk and Eggs", "Milk, Eggs and Bread".
    static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Classic edit distance, for transcription slips ("shoping").
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Compact JSON for Claude, keys sorted.
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: Finding a list by its spoken name

/// A reminder list as the matcher sees it.
struct ReminderListEntry: Sendable, Equatable {
    let id: String
    let title: String
}

enum ReminderListMatch: Equatable {
    /// `how` is for the activity log only: exact, synonym, similar, default.
    case found(id: String, how: String)
    case ambiguous(ids: [String])
    case none
}

enum ReminderListMatcher {
    private static let filler: Set<String> = [
        "my", "the", "a", "an", "our", "list", "lists", "on", "for", "of", "in",
        "liste", "listen", "meine", "mein", "die", "der", "lista", "mea",
    ]

    /// Words that mean the same kind of list in English, German, Romanian and a few other languages. A list title
    /// hits a group when one of its words is in the group, or, for words of five letters or more, contains one
    /// (German compounds: "Einkaufsliste" hits "einkauf").
    private static let synonymGroups: [String: [String]] = [
        "shopping": ["shopping", "shop", "groceries", "grocery", "grocer", "food", "supermarket", "market", "store", "buy",
                     "einkauf", "einkaufe", "einkaufen", "einkaufsliste", "einkaufszettel", "lebensmittel",
                     "cumparaturi", "alimente", "magazin", "courses", "compras", "spesa"],
        "todo": ["todo", "todos", "task", "tasks", "reminders", "reminder", "inbox", "aufgaben", "erinnerungen",
                 "sarcini", "taches"],
        "work": ["work", "office", "job", "business", "arbeit", "buro", "buero", "munca", "serviciu", "birou"],
        "home": ["home", "house", "household", "chores", "haushalt", "zuhause", "hause", "acasa", "casa"],
        "family": ["family", "familie", "familia", "kids"],
        "personal": ["personal", "private", "privat", "me", "mine"],
        "errands": ["errands", "errand", "besorgungen"],
        "travel": ["travel", "trip", "packing", "vacation", "holiday", "holidays", "urlaub", "reise", "packliste",
                   "calatorie", "vacanta"],
        "gifts": ["gifts", "gift", "presents", "present", "geschenke", "geschenk", "cadouri", "cadou"],
        "watch": ["movies", "movie", "films", "film", "watch", "shows", "tv", "filme"],
        "books": ["books", "book", "reading", "read", "bucher", "buecher", "carti"],
        "ideas": ["ideas", "idea", "ideen", "idei"],
        "health": ["health", "doctor", "medical", "gesundheit", "sanatate"],
        "garden": ["garden", "garten", "gradina"],
        "car": ["car", "auto", "masina"],
    ]

    private static func groups(of words: [String]) -> Set<String> {
        let joined = words.joined(separator: " ")
        var hits: Set<String> = []
        for (group, members) in synonymGroups {
            for member in members where words.contains(member) || (member.count >= 5 && joined.contains(member)) {
                hits.insert(group)
                break
            }
        }
        return hits
    }

    /// Finds the list the owner meant. Tries, in order: the same name; the same words in another order; a synonym
    /// ("groceries" → "Shopping", "Einkauf"); a prefix; a contained name; a small slip; and "to-do"/"tasks" for the
    /// default list. A tie at the best step is ambiguous: the caller asks rather than guesses.
    static func match(_ spoken: String, among lists: [ReminderListEntry], defaultID: String?) -> ReminderListMatch {
        let query = ReminderText.words(spoken, dropping: filler)
        let queryText = query.joined(separator: " ")
        guard !queryText.isEmpty, !lists.isEmpty else { return .none }
        let queryGroups = groups(of: query)

        var best = 0
        var winners: [ReminderListEntry] = []
        var how = ""
        for list in lists {
            let title = ReminderText.words(list.title, dropping: filler)
            let titleText = title.joined(separator: " ")
            guard !titleText.isEmpty else { continue }
            var score = 0
            var kind = ""
            if titleText == queryText {
                score = 100; kind = "exact"
            } else if Set(title) == Set(query) {
                score = 95; kind = "exact"
            } else if !queryGroups.isDisjoint(with: groups(of: title)) {
                score = 80; kind = "synonym"
            } else if min(titleText.count, queryText.count) >= 3,
                      titleText.hasPrefix(queryText) || queryText.hasPrefix(titleText) {
                score = 70; kind = "similar"
            } else if min(titleText.count, queryText.count) >= 4,
                      titleText.contains(queryText) || queryText.contains(titleText) {
                score = 60; kind = "similar"
            } else if min(titleText.count, queryText.count) >= 4,
                      ReminderText.editDistance(titleText, queryText) <= max(1, min(titleText.count, queryText.count) / 4) {
                score = 50; kind = "similar"
            }
            if score > best {
                best = score; winners = [list]; how = kind
            } else if score == best, score > 0 {
                winners.append(list)
            }
        }

        if best >= 95 {
            // Two lists with the very same name (two accounts): prefer the default, else the first.
            let pick = winners.first { $0.id == defaultID } ?? winners[0]
            return .found(id: pick.id, how: how)
        }
        if best > 0 {
            return winners.count == 1 ? .found(id: winners[0].id, how: how) : .ambiguous(ids: winners.map(\.id))
        }
        if queryGroups.contains("todo"), let defaultID, lists.contains(where: { $0.id == defaultID }) {
            return .found(id: defaultID, how: "default")
        }
        return .none
    }
}

// MARK: Matching a reminder by what was said

enum ReminderTitleMatcher {
    private static let filler: Set<String> = ["the", "a", "an", "my", "some", "our"]

    /// "eggs" and "egg" are the same word here.
    private static func stem(_ word: String) -> String {
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static func words(_ text: String) -> [String] {
        ReminderText.words(text, dropping: filler).map(stem)
    }

    /// How well a reminder's title matches what was said: 100 the same, 0 not at all. Below 60 isn't a match.
    static func score(query: String, title: String) -> Int {
        let q = words(query), t = words(title)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        let qText = q.joined(separator: " "), tText = t.joined(separator: " ")
        if qText == tText { return 100 }
        let qSet = Set(q), tSet = Set(t)
        if qSet == tSet { return 95 }
        // "milk" in "Oat milk": a good match, a little weaker for every extra word, so "Milk" beats "Oat milk".
        if qSet.isSubset(of: tSet) { return max(75, 85 - (tSet.count - qSet.count)) }
        if min(qText.count, tText.count) >= 3, qText.hasPrefix(tText) || tText.hasPrefix(qText) { return 70 }
        if tSet.isSubset(of: qSet) { return 68 }
        let shorter = min(qText.count, tText.count)
        if shorter >= 4, ReminderText.editDistance(qText, tText) <= max(1, shorter / 5) { return 62 }
        return 0
    }

    /// Same words, for spotting duplicates when adding ("Milk" is already on Shopping).
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        return !x.isEmpty && x == y
    }
}

// MARK: Due dates

/// A due date as Claude gave it, in the owner's local time: a day, or a day and a time.
struct ReminderDue: Sendable, Equatable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int?
    var minute: Int?

    var hasTime: Bool { hour != nil }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The moment it's due (the start of the day for a whole-day reminder).
    func date(in timeZone: TimeZone) -> Date? {
        Self.calendar(timeZone).date(from: DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0))
    }

    /// What EventKit stores: a Gregorian date in the owner's time zone, or a floating day for a whole-day reminder.
    func components(in timeZone: TimeZone) -> DateComponents {
        var components = DateComponents()
        components.calendar = Self.calendar(timeZone)
        components.year = year
        components.month = month
        components.day = day
        if let hour, let minute {
            components.timeZone = timeZone
            components.hour = hour
            components.minute = minute
        }
        return components
    }

    /// Reads "2026-10-27T09:00", "2026-10-27 09:00:00", "2026-10-27", and, if Claude adds an offset anyway,
    /// "2026-10-27T09:00+02:00" or "…Z" (converted to the owner's local time). Nil for anything else or an
    /// impossible date.
    static func parse(_ raw: String, timeZone: TimeZone) -> ReminderDue? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(text)
        guard chars.count >= 10 else { return nil }
        let dayParts = String(chars[0..<10]).split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.count == 3, dayParts[0].count == 4,
              let year = Int(dayParts[0]), let month = Int(dayParts[1]), let day = Int(dayParts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }

        var rest = String(chars[10...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return valid(ReminderDue(year: year, month: month, day: day), in: timeZone) }
        if rest.first == "T" || rest.first == "t" { rest.removeFirst() }

        // Split off an offset: "Z", "+02:00", "+0200", "-05".
        var offset: TimeZone?
        if rest.hasSuffix("Z") || rest.hasSuffix("z") {
            offset = TimeZone(secondsFromGMT: 0)
            rest.removeLast()
        } else if let sign = rest.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let digits = rest[rest.index(after: sign)...].filter(\.isNumber)
            guard digits.count == 2 || digits.count == 4, let value = Int(digits) else { return nil }
            let hours = digits.count == 2 ? value : value / 100
            let minutes = digits.count == 2 ? 0 : value % 100
            let seconds = (hours * 3600 + minutes * 60) * (rest[sign] == "-" ? -1 : 1)
            offset = TimeZone(secondsFromGMT: seconds)
            rest = String(rest[..<sign])
        }

        let timeParts = rest.split(separator: ":")
        guard timeParts.count >= 2, timeParts.count <= 3,
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1].prefix(2)),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let local = ReminderDue(year: year, month: month, day: day, hour: hour, minute: minute)

        guard let offset else { return valid(local, in: timeZone) }
        guard let checked = valid(local, in: offset), let moment = checked.date(in: offset) else { return nil }
        let parts = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: moment)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return nil }
        return ReminderDue(year: y, month: m, day: d, hour: parts.hour, minute: parts.minute)
    }

    /// Rejects dates that don't exist (30 February).
    private static func valid(_ due: ReminderDue, in timeZone: TimeZone) -> ReminderDue? {
        guard let date = due.date(in: timeZone) else { return nil }
        let back = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        guard back.year == due.year, back.month == due.month, back.day == due.day else { return nil }
        return due
    }
}

/// How due dates read: for Claude, "2026-10-27 09:00 (tomorrow)"; for Chats, "tomorrow 09:00".
enum ReminderDates {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// A stored due date as a moment and whether it's a whole day. Floating dates use the owner's time zone.
    static func resolve(_ components: DateComponents?, timeZone: TimeZone) -> (date: Date, allDay: Bool)? {
        guard let components, let year = components.year, let month = components.month, let day = components.day else { return nil }
        let zone = components.timeZone ?? timeZone
        let allDay = components.hour == nil
        let fields = DateComponents(year: year, month: month, day: day, hour: components.hour ?? 0, minute: components.minute ?? 0)
        guard let date = ReminderDue.calendar(zone).date(from: fields) else { return nil }
        return (date, allDay)
    }

    /// Whole days from today to `date`'s day: 0 today, 1 tomorrow, -1 yesterday.
    static func dayOffset(_ date: Date, now: Date, timeZone: TimeZone) -> Int {
        let calendar = ReminderDue.calendar(timeZone)
        let from = calendar.startOfDay(for: now), to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    static func isOverdue(_ date: Date, allDay: Bool, now: Date, timeZone: TimeZone) -> Bool {
        allDay ? dayOffset(date, now: now, timeZone: timeZone) < 0 : date < now
    }

    private static func relativeWord(_ offset: Int, date: Date, timeZone: TimeZone) -> String? {
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6, -6 ... -2:
            let formatter = DateFormatter()
            formatter.locale = posix
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE"
            return (offset < 0 ? "last " : "") + formatter.string(from: date)
        default: return nil
        }
    }

    /// For Claude: "2026-10-27 09:00 (tomorrow)", "2026-10-30 (Friday, all day)".
    static func forClaude(_ date: Date, allDay: Bool, now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = timeZone
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        let base = formatter.string(from: date)
        let word = relativeWord(dayOffset(date, now: now, timeZone: timeZone), date: date, timeZone: timeZone)
        switch (word, allDay) {
        case (let word?, true): return "\(base) (\(word), all day)"
        case (let word?, false): return "\(base) (\(word))"
        case (nil, true): return "\(base) (all day)"
        case (nil, false): return base
        }
    }

    /// For Chats, in the owner's own time format: "tomorrow 09:00", "Fri 30 Oct".
    static func forChats(_ date: Date, allDay: Bool, now: Date, timeZone: TimeZone) -> String {
        let offset = dayOffset(date, now: now, timeZone: timeZone)
        var dayStyle = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated).day().month(.abbreviated)
        dayStyle.timeZone = timeZone
        let day: String
        switch offset {
        case 0: day = "today"
        case 1: day = "tomorrow"
        default: day = date.formatted(dayStyle)
        }
        guard !allDay else { return day }
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = timeZone
        return "\(day) \(date.formatted(timeStyle))"
    }

    /// "2026-10-26 19:52", for telling Claude the time when its due time has already passed.
    static func now(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
