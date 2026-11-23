import Foundation
import ReGlassAssistant

/// Local time for one tool call, in the turn's time zone. Reads Claude's wall-clock times ("2026-10-29T13:00",
/// "2026-10-29") and writes results with the weekday ("Thu 2026-10-29T13:00") and a day word ("tomorrow"), so
/// Claude never does date maths itself. Built with an explicit Gregorian calendar, so it's safe across daylight
/// saving changes.
struct CalClock {
    struct Moment {
        let date: Date
        /// False for a date alone.
        let hasTime: Bool
    }

    /// A stretch of time to read.
    struct Span {
        var start: Date
        var end: Date
        var startHasTime: Bool
        var endHasTime: Bool
        /// The named range it came from ("today"), if any.
        var name: String?
        /// Shortened to the tool's longest span.
        var clipped = false
    }

    struct Failure: Error {
        let sentence: String
    }

    static let rangeNames = ["today", "rest_of_today", "tomorrow", "this_week", "next_week", "this_weekend",
                             "next_7_days", "upcoming"]

    let now: Date
    let timeZone: TimeZone
    let calendar: Calendar
    private let stampFormat: DateFormatter
    private let dayFormat: DateFormatter
    private let wordFormat: DateFormatter
    private let clockFormat: DateFormatter
    private let chatDayFormat: DateFormatter
    private let chatTimeFormat: DateFormatter

    init(_ context: ToolContext) {
        now = context.date
        timeZone = context.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = Calendar.current.firstWeekday
        self.calendar = calendar

        func formatter(_ format: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = context.timeZone
            formatter.calendar = calendar
            formatter.dateFormat = format
            return formatter
        }
        stampFormat = formatter("EEE yyyy-MM-dd'T'HH:mm")
        dayFormat = formatter("EEE yyyy-MM-dd")
        wordFormat = formatter("EEEE d MMMM")
        clockFormat = formatter("HH:mm")
        // For Chats, in the owner's own format.
        let chatDay = formatter("", locale: .current)
        chatDay.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let chatTime = formatter("", locale: .current)
        chatTime.setLocalizedDateFormatFromTemplate("jmm")
        chatDayFormat = chatDay
        chatTimeFormat = chatTime
    }

    // MARK: Days

    func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    func isMidnight(_ date: Date) -> Bool { startOfDay(date) == date }

    // MARK: Reading Claude's times

    /// "2026-10-29", "2026-10-29T13:00", "2026-10-29 13:00:00", "now". Times are local wall-clock; an offset or
    /// "Z", if Claude adds one anyway, is honoured.
    func parse(_ raw: String) -> Moment? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "now" { return Moment(date: now, hasTime: true) }
        let pieces = text.split(whereSeparator: { $0 == "T" || $0 == " " }).map(String.init)
        guard (1...2).contains(pieces.count) else { return nil }
        let ymd = pieces[0].split(separator: "-")
        guard ymd.count == 3, let year = Int(ymd[0]), let month = Int(ymd[1]), let day = Int(ymd[2]),
              (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }

        var zone = timeZone
        var hour = 0, minute = 0, second = 0
        var hasTime = false
        if pieces.count == 2 {
            var time = pieces[1]
            if time.hasSuffix("Z") || time.hasSuffix("z") {
                zone = TimeZone(secondsFromGMT: 0) ?? zone
                time.removeLast()
            } else if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                let digits = time[time.index(after: sign)...].replacingOccurrences(of: ":", with: "")
                guard digits.count == 2 || digits.count == 4, let value = Int(digits) else { return nil }
                let hours = digits.count == 4 ? value / 100 : value
                let minutes = digits.count == 4 ? value % 100 : 0
                let seconds = (hours * 3600 + minutes * 60) * (time[sign] == "-" ? -1 : 1)
                guard let offsetZone = TimeZone(secondsFromGMT: seconds) else { return nil }
                zone = offsetZone
                time = String(time[..<sign])
            }
            let hms = time.split(separator: ":")
            guard (2...3).contains(hms.count), let h = Int(hms[0]), let m = Int(hms[1]),
                  (0...24).contains(h), (0...59).contains(m) else { return nil }
            hour = h
            minute = m
            if hms.count == 3, let s = Double(hms[2]), s.isFinite, (0..<60).contains(s) { second = Int(s) }
            if hour == 24 && (minute != 0 || second != 0) { return nil }
            hasTime = true
        }

        var local = calendar
        local.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour == 24 ? 0 : hour, minute: minute, second: second)
        guard var date = local.date(from: components),
              local.component(.day, from: date) == day else { return nil } // 31 April rolls over: refuse it
        if hour == 24 { date = local.date(byAdding: .day, value: 1, to: date) ?? date }
        return Moment(date: date, hasTime: hasTime)
    }

    /// The span a read tool should cover: `start`/`end` if given (a date alone as `end` includes that whole day),
    /// otherwise `range`, otherwise `defaultRange`. Capped at `maxDays`.
    func span(from input: JSONValue, defaultRange: String, maxDays: Int) -> Result<Span, Failure> {
        let startText = Self.text(input["start"])
        let endText = Self.text(input["end"])
        var span: Span

        if startText != nil || endText != nil {
            let start: Moment
            if let startText {
                guard let parsed = parse(startText) else { return .failure(Self.unreadable("start", startText)) }
                start = parsed
            } else {
                start = Moment(date: now, hasTime: true)
            }
            let startDate = start.hasTime ? start.date : startOfDay(start.date)
            var endDate = adding(days: 1, to: startOfDay(start.date))
            var endHasTime = false
            if let endText {
                guard let parsed = parse(endText) else { return .failure(Self.unreadable("end", endText)) }
                endDate = parsed.hasTime ? parsed.date : adding(days: 1, to: startOfDay(parsed.date))
                endHasTime = parsed.hasTime
            }
            span = Span(start: startDate, end: endDate, startHasTime: start.hasTime, endHasTime: endHasTime)
        } else {
            let name = Self.text(input["range"])?.lowercased() ?? defaultRange
            guard let named = named(name) else {
                return .failure(Failure(sentence: "Unknown range \"\(name)\". Use one of \(Self.rangeNames.joined(separator: ", ")), or give start and end."))
            }
            span = named
        }

        guard span.end > span.start else { return .failure(Failure(sentence: "The end is before the start.")) }
        let cap = adding(days: maxDays, to: span.start)
        if span.end > cap {
            span.end = cap
            span.clipped = true
        }
        return .success(span)
    }

    /// The named ranges in the tools' schemas, plus "search" (the next 60 days, for finding one event by name).
    func named(_ name: String) -> Span? {
        let today = startOfDay(now)
        func days(_ from: Date, _ count: Int, timed: Bool = false) -> Span {
            Span(start: from, end: adding(days: count, to: startOfDay(from)), startHasTime: timed, endHasTime: false,
                 name: name)
        }
        switch name {
        case "today":
            return days(today, 1)
        case "rest_of_today":
            return days(now, 1, timed: true)
        case "tomorrow":
            return days(adding(days: 1, to: today), 1)
        case "this_week":
            let end = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? adding(days: 7, to: today)
            return Span(start: today, end: end, startHasTime: false, endHasTime: false, name: name)
        case "next_week":
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? adding(days: 7, to: today)
            return days(start, 7)
        case "this_weekend":
            let weekday = calendar.component(.weekday, from: now) // 1 Sunday … 7 Saturday
            switch weekday {
            case 7: return days(today, 2)
            case 1: return days(today, 1)
            default: return days(adding(days: 7 - weekday, to: today), 2)
            }
        case "next_7_days":
            return days(today, 7)
        case "upcoming":
            return Span(start: now, end: now.addingTimeInterval(14 * 86_400), startHasTime: true, endHasTime: true,
                        name: name)
        case "search":
            return Span(start: today, end: adding(days: 60, to: today), startHasTime: false, endHasTime: false,
                        name: name)
        default:
            return nil
        }
    }

    // MARK: Writing results

    /// "Thu 2026-10-29T13:00"
    func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    /// "Thu 2026-10-29"
    func dayStamp(_ date: Date) -> String { dayFormat.string(from: date) }

    /// "13:00"
    func clock(_ date: Date, in zone: TimeZone? = nil) -> String {
        guard let zone else { return clockFormat.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "today", "tomorrow", "yesterday", else "Friday 30 October".
    func dayWord(_ date: Date) -> String {
        let days = calendar.dateComponents([.day], from: startOfDay(now), to: startOfDay(date)).day ?? 99
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        default: return wordFormat.string(from: date)
        }
    }

    /// For Chats: "Thu 29 Oct" or "Thu 29 Oct, 13:00" in the owner's own format.
    func chatDay(_ date: Date, time: Bool = false) -> String {
        let day = chatDayFormat.string(from: date)
        return time ? "\(day), \(chatTimeFormat.string(from: date))" : day
    }

    /// For Chats: what a span covered ("Tomorrow", "This week", "Fri 30 Oct").
    func chatLabel(_ span: Span) -> String {
        switch span.name {
        case "today": return "Today"
        case "rest_of_today": return "Rest of today"
        case "tomorrow": return "Tomorrow"
        case "this_week": return "This week"
        case "next_week": return "Next week"
        case "this_weekend": return "This weekend"
        case "next_7_days": return "Next 7 days"
        case "upcoming": return "Coming up"
        case "search": return "Next 60 days"
        default: break
        }
        let lastInstant = span.end.addingTimeInterval(-1)
        if startOfDay(span.start) == startOfDay(lastInstant) {
            let day = chatDay(span.start)
            guard span.startHasTime || span.endHasTime else { return day }
            return "\(day), \(chatTimeFormat.string(from: span.start))–\(chatTimeFormat.string(from: span.end))"
        }
        return "\(chatDay(span.start)) – \(chatDay(lastInstant))"
    }

    // MARK: Input helpers

    /// A non-empty trimmed string, or nil.
    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func unreadable(_ field: String, _ text: String) -> Failure {
        Failure(sentence: "I couldn't read the \(field) \"\(text)\". Use 2026-10-30 for a day or 2026-10-30T13:00 for a time.")
    }

    /// Compact JSON with sorted keys for a tool result.
    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
