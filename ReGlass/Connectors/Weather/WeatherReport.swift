import Foundation
import ReGlassAssistant

// A forecast in one shape whatever the source (Open-Meteo today, Apple Weather later), always metric:
// °C, mm, km/h, chances in percent. Sources fill it; `WeatherBrief` slices it for one question.

struct WeatherReport: Sendable {
    /// The sky in a few words ("light rain", "partly cloudy") and what kind of weather it is.
    struct Sky: Sendable, Equatable {
        enum Kind: Int, Sendable, Comparable {
            case dry, fog, rain, snow, storm

            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        var text: String
        var kind: Kind
    }

    struct Now: Sendable {
        var time: Date
        var temperature: Double
        var feelsLike: Double?
        var sky: Sky
        var windKmh: Double?
        var gustKmh: Double?
        /// 0–100
        var humidity: Double?
    }

    struct Hour: Sendable {
        /// The start of the hour.
        var time: Date
        var temperature: Double
        var feelsLike: Double?
        var sky: Sky
        /// 0–100
        var rainChance: Double?
        var precipitationMm: Double?
        var windKmh: Double?
        var gustKmh: Double?
        var uvIndex: Double?
    }

    struct Day: Sendable {
        /// Local midnight at the place.
        var start: Date
        var high: Double?
        var low: Double?
        var sky: Sky
        /// 0–100, the highest of the day.
        var rainChance: Double?
        var precipitationMm: Double?
        var windMaxKmh: Double?
        var gustMaxKmh: Double?
        var uvMax: Double?
        var sunrise: Date?
        var sunset: Date?
    }

    /// The place's time zone: "today" and "tomorrow" are the place's, not the iPhone's.
    var timeZone: TimeZone
    var now: Now?
    /// Hour by hour from local midnight today, about 8 days.
    var hours: [Hour]
    /// From today, about 8 days.
    var days: [Day]
    /// "Open-Meteo", "Apple Weather".
    var source: String
}

// MARK: - The question

/// What Claude asked for, after checking its input.
struct WeatherQuery: Sendable, Equatable {
    enum Day: Sendable, Equatable {
        case today
        case tomorrow
        case date(year: Int, month: Int, day: Int)
        /// 1 = Sunday … 7 = Saturday (`Calendar` numbering): the next such day, today included.
        case weekday(Int)
    }

    enum PartOfDay: String, Sendable, CaseIterable {
        case morning, afternoon, evening, night

        /// Start and end hour (end may pass midnight: 30 = 06:00 the next day).
        var hours: (start: Int, end: Int) {
            switch self {
            case .morning: return (6, 12)
            case .afternoon: return (12, 18)
            case .evening: return (18, 24)
            case .night: return (18, 30)
            }
        }
    }

    enum When: Sendable, Equatable {
        case now
        case nextHours(Int)
        case day(Day, PartOfDay?)
        case tonight
        case week
    }

    /// Nil: where the owner is now.
    var place: String?
    var when: When
}

extension WeatherQuery {
    /// Reads Claude's input leniently: it can use other words than the schema's ("this afternoon", "friday").
    init?(input: JSONValue) {
        guard input.object != nil else { return nil }
        let rawPlace = input["place"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        place = rawPlace.isEmpty ? nil : rawPlace

        let part = Self.part(input["part_of_day"]?.string)
        let date = input["date"]?.string.flatMap(Self.day)
        let hours = input["hours"]?.int ?? input["hours"]?.string.flatMap { Int($0) }
        let word = Self.normalized(input["when"]?.string)

        switch word {
        case "", "now", "current", "currently", "right_now":
            when = date.map { .day($0, part) } ?? (part.map { .day(.today, $0) } ?? .now)
        case "next_hours", "next_hour", "hourly", "soon", "coming_hours":
            when = .nextHours(min(max(hours ?? (word == "next_hour" ? 1 : 3), 1), 24))
        case "today", "rest_of_today", "this_day":
            when = .day(.today, part)
        case "tonight", "this_night", "overnight":
            when = .tonight
        case "tomorrow":
            when = .day(.tomorrow, part)
        case "day", "date", "on":
            guard let date else { return nil }
            when = .day(date, part)
        case "week", "this_week", "weekend", "this_weekend", "next_days", "next_7_days", "7_days":
            when = .week
        default:
            // "this_afternoon", "tomorrow_morning", "friday", "2026-10-30"
            if let found = PartOfDay.allCases.first(where: { word.hasSuffix($0.rawValue) }) {
                let prefix = String(word.dropLast(found.rawValue.count)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                let named = (prefix.isEmpty || prefix == "this") ? nil : Self.day(prefix)
                when = .day(named ?? date ?? .today, found)
            } else if let day = Self.day(word) {
                when = .day(day, part)
            } else if let date {
                when = .day(date, part)
            } else {
                return nil
            }
        }
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
    }

    private static func part(_ text: String?) -> PartOfDay? {
        switch normalized(text) {
        case "morning": return .morning
        case "afternoon", "midday", "noon": return .afternoon
        case "evening": return .evening
        case "night", "overnight", "tonight": return .night
        default: return nil
        }
    }

    /// "today", "tomorrow", "2026-10-30" (a full timestamp is cut to its date) or a weekday name.
    static func day(_ text: String) -> Day? {
        let word = normalized(text)
        if word == "today" { return .today }
        if word == "tomorrow" { return .tomorrow }
        let digits = String(text.trimmingCharacters(in: .whitespaces).prefix(10))
        let parts = digits.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, parts[0] > 2000, (1...12).contains(parts[1]), (1...31).contains(parts[2]) {
            return .date(year: parts[0], month: parts[1], day: parts[2])
        }
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let bare = word.hasPrefix("next_") ? String(word.dropFirst(5)) : (word.hasPrefix("this_") ? String(word.dropFirst(5)) : word)
        if bare.count >= 3, let index = names.firstIndex(where: { bare.hasPrefix($0) }) { return .weekday(index + 1) }
        return nil
    }

    /// For the Chats line: "now", "tomorrow afternoon", "Friday".
    var label: String {
        switch when {
        case .now: return "now"
        case .nextHours(let hours): return hours == 1 ? "next hour" : "next \(hours) hours"
        case .tonight: return "tonight"
        case .week: return "this week"
        case .day(let day, let part):
            let dayWord: String
            switch day {
            case .today: dayWord = part == nil ? "today" : "this"
            case .tomorrow: dayWord = "tomorrow"
            case .date(let year, let month, let date):
                let calendar = WeatherBrief.englishCalendar(.current)
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = calendar.locale
                formatter.dateFormat = "EEEE d MMMM"
                dayWord = calendar.date(from: DateComponents(year: year, month: month, day: date)).map(formatter.string)
                    ?? String(format: "%04d-%02d-%02d", year, month, date)
            case .weekday(let weekday):
                dayWord = WeatherBrief.englishCalendar(.current).weekdaySymbols[(weekday - 1) % 7]
            }
            guard let part else { return dayWord }
            if day == .today, part == .night { return "tonight" }
            return "\(dayWord) \(part.rawValue)"
        }
    }
}
