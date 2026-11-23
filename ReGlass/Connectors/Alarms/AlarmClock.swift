import Foundation
import ReGlassAssistant

/// Turns what Claude passes for an alarm (a local wall-clock time, maybe a date, days to repeat on, or "in N
/// minutes") into the moment it rings, and describes alarms back in words Claude can say ("tomorrow morning"). Claude
/// never does the clock arithmetic. Uses an explicit Gregorian calendar in the turn's time zone, so it's safe across
/// daylight saving changes.
///
/// The rules:
/// - "at seven" with no am/pm: whichever of 07:00 and 19:00 comes sooner. Claude marks "wake me ..." as morning.
/// - A time of day that has already passed today: tomorrow.
/// - Repeats are weekly only (some days, weekdays, weekends, every day). A repeating time with no am/pm: morning.
/// - "In twenty minutes": a fixed moment from now.
struct AlarmClock {
    struct ClockTime: Equatable, Codable {
        var hour: Int
        var minute: Int
    }

    /// When and how an alarm rings, ready for AlarmKit.
    enum Plan: Equatable {
        /// The next time this time of day comes round (follows the phone's time zone when travelling).
        case next(ClockTime, fire: Date)
        /// Every week on these days (Calendar weekday numbers, 1 = Sunday).
        case weekly(ClockTime, days: [Int], fire: Date)
        /// One fixed moment (a given date, or "in N minutes").
        case fixed(Date)

        var fire: Date {
            switch self {
            case .next(_, let fire), .weekly(_, _, let fire): return fire
            case .fixed(let date): return date
            }
        }
    }

    struct Resolved: Equatable {
        let plan: Plan
        /// The time had passed today only a little while ago, so it's set for tomorrow: worth saying.
        let rolledOver: Bool
        /// No am/pm was given and ReGlass chose: "morning", "evening".
        let assumedPart: String?
    }

    struct Failure: Error {
        let sentence: String
        let chat: String
    }

    static let maxMinutesAhead = 1_440
    /// A time that passed today less than this long ago rolls to tomorrow *with a mention*.
    static let rolloverMention: TimeInterval = 4 * 3600

    let now: Date
    let timeZone: TimeZone
    let calendar: Calendar
    private let stampFormat: DateFormatter
    private let clockFormat: DateFormatter
    private let weekdayFormat: DateFormatter
    private let longDayFormat: DateFormatter
    private let chatTimeFormat: DateFormatter
    private let chatDayFormat: DateFormatter

    init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = Calendar.current.firstWeekday
        self.calendar = calendar

        func formatter(_ format: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.calendar = calendar
            formatter.dateFormat = format
            return formatter
        }
        stampFormat = formatter("EEE yyyy-MM-dd HH:mm")
        clockFormat = formatter("HH:mm")
        weekdayFormat = formatter("EEEE")
        longDayFormat = formatter("EEEE d MMMM")
        // For Chats and Settings, in the owner's own format ("7:00 AM" or "07:00").
        let chatTime = formatter("", locale: .current)
        chatTime.setLocalizedDateFormatFromTemplate("jmm")
        chatTimeFormat = chatTime
        let chatDay = formatter("", locale: .current)
        chatDay.setLocalizedDateFormatFromTemplate("EEEdMMM")
        chatDayFormat = chatDay
    }

    init(_ context: ToolContext) {
        // The call runs within seconds of the request; the alarm counts from the real now.
        self.init(now: Date(), timeZone: context.timeZone)
    }

    // MARK: Reading Claude's input

    /// "07:00", "7:00", "7", "19:30", "7:00 pm", "7pm". `periodGiven` is true when the text itself settles am/pm
    /// (a suffix, or an hour that can only be one: 0, 13–23).
    static func parseTime(_ raw: String?) -> (time: ClockTime, periodGiven: Bool)? {
        guard var text = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        var suffix: String?
        for candidate in ["am", "pm", "a", "p"] where text.hasSuffix(candidate) {
            suffix = candidate.hasPrefix("a") ? "am" : "pm"
            text.removeLast(candidate.count)
            break
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let hour = Int(parts[0]) else { return nil }
        let minute = parts.count >= 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute) else { return nil }
        if let suffix {
            guard (1...12).contains(hour) else { return nil }
            let h = hour % 12 + (suffix == "pm" ? 12 : 0)
            return (ClockTime(hour: h, minute: minute), true)
        }
        guard (0...24).contains(hour) else { return nil }
        let h = hour == 24 ? 0 : hour
        return (ClockTime(hour: h, minute: minute), h == 0 || h > 12)
    }

    /// "2026-10-30" (a time after a "T" or space is ignored).
    static func parseDay(_ raw: String?) -> DateComponents? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let day = text.split(whereSeparator: { $0 == "T" || $0 == " " }).first.map(String.init) ?? text
        let ymd = day.split(separator: "-")
        guard ymd.count == 3, let y = Int(ymd[0]), let m = Int(ymd[1]), let d = Int(ymd[2]),
              (2000...2200).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    /// Days to repeat on, as Calendar weekday numbers (1 = Sunday), from ["mon", "wed"], "weekdays", "every day"...
    /// Nil: something that isn't a day of the week. Empty: no repeat.
    static func parseDays(_ value: JSONValue?) -> Set<Int>? {
        guard let value else { return [] }
        if case .null = value { return [] }
        var tokens: [String] = []
        if let array = value.array {
            tokens = array.compactMap(\.string)
            guard tokens.count == array.count else { return nil }
        } else if let text = value.string {
            tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" }).map(String.init)
        } else {
            return nil
        }
        var days: Set<Int> = []
        for raw in tokens {
            let token = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            switch token {
            case "", "never", "none", "once", "no": continue
            case "weekdays", "weekday", "workdays", "work days", "mon fri", "monday to friday":
                days.formUnion([2, 3, 4, 5, 6])
            case "weekends", "weekend":
                days.formUnion([1, 7])
            case "daily", "every day", "everyday", "all", "all days", "each day":
                days.formUnion(1...7)
            default:
                let key = String(token.prefix(3))
                let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
                guard let day = names[key] else { return nil }
                days.insert(day)
            }
        }
        return days
    }

    // MARK: Resolving

    /// - Parameters:
    ///   - time: a time of day, nil only with `inMinutes`.
    ///   - amPmKnown: the user made clear whether it's morning or evening (Claude's flag).
    ///   - day: a specific date ("Friday at seven").
    ///   - inMinutes: "in twenty minutes"; wins over everything else.
    ///   - days: weekly repeat days (empty for a one-off).
    func resolve(time rawTime: String?, amPmKnown: Bool, day rawDay: String?, inMinutes: Int?,
                 days: Set<Int>) -> Result<Resolved, Failure> {
        if let inMinutes {
            guard (1...Self.maxMinutesAhead).contains(inMinutes) else {
                return .failure(Failure(sentence: "An alarm 'in' some minutes can be up to twenty-four hours away. For later, give a time of day.",
                                        chat: "Up to 24 hours ahead"))
            }
            let fire = now.addingTimeInterval(TimeInterval(inMinutes * 60))
            return .success(Resolved(plan: .fixed(fire), rolledOver: false, assumedPart: nil))
        }
        guard let parsed = Self.parseTime(rawTime) else {
            return .failure(Failure(sentence: "ReGlass needs a time for the alarm, such as 07:00.", chat: "No time given"))
        }
        let time = parsed.time
        let known = amPmKnown || parsed.periodGiven
        // Ambiguous: the morning and the evening reading of a 1–12 hour.
        let base = time.hour % 12
        let readings: [ClockTime] = known ? [time]
            : [ClockTime(hour: base, minute: time.minute), ClockTime(hour: base + 12, minute: time.minute)]

        if !days.isEmpty {
            // A repeating alarm without am/pm is a morning alarm ("six forty-five on weekdays"); 12 means noon.
            let chosen = known ? time : ClockTime(hour: time.hour == 12 ? 12 : base, minute: time.minute)
            guard let fire = nextWeekly(chosen, days: days) else {
                return .failure(Failure(sentence: "ReGlass couldn't work out when that alarm would ring.", chat: "Couldn't work out the time"))
            }
            return .success(Resolved(plan: .weekly(chosen, days: days.sorted(), fire: fire), rolledOver: false,
                                     assumedPart: known ? nil : partOfDay(chosen.hour)))
        }

        if let rawDay {
            guard let components = Self.parseDay(rawDay) else {
                return .failure(Failure(sentence: "ReGlass couldn't read that date.", chat: "Couldn't read the date"))
            }
            let candidates = readings.compactMap { reading -> Date? in
                var c = components
                c.hour = reading.hour
                c.minute = reading.minute
                c.second = 0
                return calendar.date(from: c)
            }.filter { $0 > now }.sorted()
            // Today's date with a time already gone: Claude added the date it shouldn't have; treat it as the plain
            // "at seven" below (tomorrow).
            let isToday = calendar.date(from: components).map { calendar.isDate($0, inSameDayAs: now) } ?? false
            if candidates.isEmpty, isToday {
                return resolve(time: rawTime, amPmKnown: amPmKnown, day: nil, inMinutes: nil, days: days)
            }
            guard let fire = candidates.first else {
                return .failure(Failure(sentence: "That time has already passed.", chat: "That time has passed"))
            }
            guard fire.timeIntervalSince(now) < 366 * 86_400 else {
                return .failure(Failure(sentence: "Alarms can be set up to a year ahead.", chat: "Too far ahead"))
            }
            // "Tomorrow at seven" said tonight is just "the next seven": keep it relative so it follows the time
            // zone like any other. Only a day further out needs a fixed moment.
            if let reading = readings.first(where: { next($0) == fire }) {
                return .success(Resolved(plan: .next(reading, fire: fire), rolledOver: false,
                                         assumedPart: known ? nil : partOfDay(reading.hour)))
            }
            let hour = calendar.component(.hour, from: fire)
            return .success(Resolved(plan: .fixed(fire), rolledOver: false, assumedPart: known ? nil : partOfDay(hour)))
        }

        // The next time it comes round: the sooner reading.
        let options = readings.compactMap { reading in next(reading).map { (reading, $0) } }.sorted { $0.1 < $1.1 }
        guard let (reading, fire) = options.first else {
            return .failure(Failure(sentence: "ReGlass couldn't work out when that alarm would ring.", chat: "Couldn't work out the time"))
        }
        // "Wake me at seven" at 07:20: worth saying it's tomorrow.
        var rolledOver = false
        if !calendar.isDate(fire, inSameDayAs: now), let today = todayAt(reading), today <= now,
           now.timeIntervalSince(today) < Self.rolloverMention {
            rolledOver = true
        }
        return .success(Resolved(plan: .next(reading, fire: fire), rolledOver: rolledOver,
                                 assumedPart: known ? nil : partOfDay(reading.hour)))
    }

    /// The next moment after now that this time of day comes round.
    func next(_ time: ClockTime) -> Date? {
        calendar.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                          matchingPolicy: .nextTime)
    }

    /// The next ring of a weekly alarm.
    func nextWeekly(_ time: ClockTime, days: Set<Int>) -> Date? {
        days.compactMap { day in
            calendar.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: day),
                              matchingPolicy: .nextTime)
        }.min()
    }

    private func todayAt(_ time: ClockTime) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)
    }

    // MARK: Words for Claude

    /// "morning" (00–11), "afternoon" (12–16), "evening" (17–20), "night" (21–23).
    func partOfDay(_ hour: Int) -> String {
        switch hour {
        case 0..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    /// "today", "tomorrow", "Friday" (within the week), else "Thursday 5 November".
    func dayWord(_ date: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return weekdayFormat.string(from: date)
        default: return longDayFormat.string(from: date)
        }
    }

    /// How the voice says when it rings: "this evening", "tomorrow morning", "tonight", "Friday morning". Midnight to
    /// one in the morning, coming up tonight, is "tonight".
    func spokenWhen(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        let day = dayWord(date)
        if hour == 0, day == "tomorrow" { return "tonight" }
        let part = partOfDay(hour)
        switch day {
        case "today": return part == "night" ? "tonight" : "this \(part)"
        case "tomorrow": return "tomorrow \(part)"
        default: return "\(day) \(part)"
        }
    }

    /// "07:00"
    func clock(_ date: Date) -> String { clockFormat.string(from: date) }
    func clock(_ time: ClockTime) -> String { String(format: "%02d:%02d", time.hour, time.minute) }
    /// "Wed 2026-10-28 07:00"
    func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    /// "weekdays", "weekends", "every day", "Mondays and Wednesdays".
    func repeatWords(_ days: [Int]) -> String {
        let set = Set(days)
        if set.count == 7 { return "every day" }
        if set == [2, 3, 4, 5, 6] { return "weekdays" }
        if set == [1, 7] { return "weekends" }
        let names = Self.mondayFirst(set).map { weekdayName($0) + "s" }
        return Self.joined(names)
    }

    // MARK: Words for Chats and Settings (the owner's format)

    func chatTime(_ date: Date) -> String { chatTimeFormat.string(from: date) }

    func chatTime(_ time: ClockTime) -> String {
        guard let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) else {
            return clock(time)
        }
        return chatTimeFormat.string(from: date)
    }

    /// "Today", "Tomorrow", "Fri 30 Oct".
    func chatDay(_ date: Date) -> String {
        switch dayWord(date) {
        case "today": return "Today"
        case "tomorrow": return "Tomorrow"
        default: return chatDayFormat.string(from: date)
        }
    }

    /// "Weekdays", "Weekends", "Every day", "Mon, Wed, Fri".
    func chatRepeat(_ days: [Int]) -> String {
        let set = Set(days)
        if set.count == 7 { return "Every day" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        return Self.mondayFirst(set).map { String(weekdayName($0).prefix(3)) }.joined(separator: ", ")
    }

    private func weekdayName(_ day: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][(day - 1 + 7) % 7]
    }

    private static func mondayFirst(_ days: Set<Int>) -> [Int] {
        days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
    }

    private static func joined(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }
}
