import Foundation

/// Where a forecast is for, and how ReGlass knew.
struct WeatherPlace: Sendable {
    enum Source: Sendable, Equatable {
        /// Claude named it.
        case named
        /// A fresh fix (or one a few minutes old).
        case current
        /// An older fix; its age in seconds.
        case lastKnown(TimeInterval)
        /// The home city setting.
        case homeCity
    }

    var latitude: Double
    var longitude: Double
    /// "Lyon, France". Nil when the name lookup failed.
    var name: String?
    /// For Chats: "Lyon".
    var shortName: String?
    /// From the geocoder, when known. Open-Meteo reports its own.
    var timeZone: TimeZone?
    var source: Source
}

/// The facts Claude gets for one question: short labelled lines, metric, times local to the place. Claude turns them
/// into one or two spoken sentences, so nothing here is phrased for speech.
struct WeatherBrief {
    struct Failure: Error {
        let message: String
    }

    let report: WeatherReport
    let now: Date
    private let calendar: Calendar
    private let clock: DateFormatter
    private let longDay: DateFormatter
    private let shortDay: DateFormatter

    init(report: WeatherReport, now: Date) {
        self.report = report
        self.now = now
        calendar = Self.englishCalendar(report.timeZone)
        clock = Self.formatter("HH:mm", calendar)
        longDay = Self.formatter("EEEE d MMMM", calendar)
        shortDay = Self.formatter("EEE d MMM", calendar)
    }

    static func englishCalendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: The brief

    func facts(place: WeatherPlace, query: WeatherQuery, phoneTimeZone: TimeZone) -> Result<String, Failure> {
        var lines = ["place: \(placeLine(place))", localTimeLine(phoneTimeZone: phoneTimeZone),
                     "units: °C, mm, km/h; \"rain\" is the chance of rain or snow in %"]
        switch body(for: query.when) {
        case .success(let body): lines += body
        case .failure(let failure): return .failure(failure)
        }
        lines.append("source: \(report.source)")
        return .success(lines.joined(separator: "\n"))
    }

    private func body(for when: WeatherQuery.When) -> Result<[String], Failure> {
        switch when {
        case .now:
            return .success(nowBody())
        case .nextHours(let count):
            return .success(nextHoursBody(count))
        case .tonight:
            return .success(tonightBody())
        case .week:
            return .success(weekBody())
        case .day(let day, let part):
            guard let start = dayStart(day) else {
                return .failure(Failure(message: "That date doesn't exist. Ask which day they mean."))
            }
            if start < today { return .failure(Failure(message: "That day has already passed. Ask which day they mean.")) }
            if start == today { return .success(todayBody(part)) }
            guard let data = self.day(at: start) else {
                let last = report.days.last.map { longDay.string(from: $0.start) } ?? "seven days ahead"
                return .failure(Failure(message: "The forecast only reaches \(last). Ask about a nearer day."))
            }
            return .success(dayBody(data, part: part))
        }
    }

    private func nowBody() -> [String] {
        var lines = nowLines()
        let next = hours(from: nextHour, to: hour(after: nextHour, 3))
        if !next.isEmpty { lines.append("next hours:") ; lines += next.map(hourLine) }
        if let today = day(at: today) { lines.append(dayLine(today, label: "today")) }
        lines.append(restOfTodayRain())
        return lines
    }

    private func nextHoursBody(_ count: Int) -> [String] {
        let rows = hours(from: thisHour, to: hour(after: nextHour, count))
        var lines = nowLines()
        lines.append("hour by hour (the first row is the current hour):")
        lines += rows.map(hourLine)
        lines.append(rainLine(rows, label: count == 1 ? "the next hour" : "the next \(count) hours"))
        return lines
    }

    private func todayBody(_ part: WeatherQuery.PartOfDay?) -> [String] {
        var lines = nowLines()
        if let part {
            let (start, end) = window(part, on: today)
            if end <= now {
                lines.append("note: this \(part.rawValue) is already over at the place; here is the rest of today")
                lines += restOfTodayRows()
            } else {
                let rows = hours(from: max(start, thisHour), to: end)
                lines.append("\(partLabel(part, today: true)) (\(time(start))–\(time(end))), hour by hour:")
                lines += rows.map(hourLine)
                lines.append(rainLine(rows, label: partLabel(part, today: true)))
            }
        } else {
            lines += restOfTodayRows()
        }
        if let today = day(at: today) { lines.append(dayLine(today, label: "today")) }
        return lines
    }

    private func restOfTodayRows() -> [String] {
        var rows = hours(from: nextHour, to: tomorrow)
        var label = "rest of today, hour by hour:"
        if rows.count < 3 {
            rows = hours(from: nextHour, to: hour(after: nextHour, 6))
            label = "next 6 hours (today is nearly over):"
        }
        return [label] + rows.prefix(18).map(hourLine) + [restOfTodayRain()]
    }

    private func restOfTodayRain() -> String {
        let end = max(tomorrow, hour(after: thisHour, 6))
        let label = end == tomorrow ? "the rest of today" : "the next 6 hours"
        return rainLine(hours(from: thisHour, to: end), label: label)
    }

    private func tonightBody() -> [String] {
        let start: Date
        let end: Date
        if calendar.component(.hour, from: now) < 5 {
            start = thisHour
            end = at(hour: 6, on: today)
        } else {
            start = max(at(hour: 18, on: today), thisHour)
            end = at(hour: 30, on: today)
        }
        let rows = hours(from: start, to: end)
        var lines = start == thisHour ? nowLines() : []
        lines.append("tonight (\(time(start))–\(time(end))), hour by hour:")
        lines += rows.map(hourLine)
        if let coldest = rows.min(by: { $0.temperature < $1.temperature }) {
            var low = "tonight's low: \(degrees(coldest.temperature)) around \(time(coldest.time))"
            if let feels = rows.compactMap(\.feelsLike).min(), feels < coldest.temperature - 0.5 {
                low += ", feels like \(degrees(feels)) at the coldest"
            }
            lines.append(low)
        }
        lines.append(rainLine(rows, label: "tonight"))
        var sun: [String] = []
        if let sunset = day(at: today)?.sunset, sunset > now { sun.append("sunset \(time(sunset))") }
        if let sunrise = day(at: tomorrow)?.sunrise { sun.append("sunrise tomorrow \(time(sunrise))") }
        if !sun.isEmpty { lines.append(sun.joined(separator: ", ")) }
        return lines
    }

    private func dayBody(_ data: WeatherReport.Day, part: WeatherQuery.PartOfDay?) -> [String] {
        let name = longDay.string(from: data.start)
        var lines = [dayLine(data, label: calendar.isDate(data.start, inSameDayAs: tomorrow) ? "tomorrow, \(name)" : name)]
        if let part {
            let (start, end) = window(part, on: data.start)
            let rows = hours(from: start, to: end)
            lines.append("\(part.rawValue) (\(time(start))–\(time(end))), hour by hour:")
            lines += rows.map(hourLine)
            lines.append(rainLine(rows, label: "the \(part.rawValue)"))
        } else {
            for part in [WeatherQuery.PartOfDay.morning, .afternoon, .evening] {
                let (start, end) = window(part, on: data.start)
                if let line = partLine(part.rawValue, start: start, end: end) { lines.append(line) }
            }
            let nextDay = at(hour: 24, on: data.start)
            if let line = partLine("overnight into \(Self.formatter("EEEE", calendar).string(from: nextDay))",
                                   start: nextDay, end: at(hour: 30, on: data.start)) {
                lines.append(line)
            }
            lines.append(rainLine(hours(from: at(hour: 6, on: data.start), to: nextDay), label: "06:00 to midnight"))
        }
        return lines
    }

    private func weekBody() -> [String] {
        var lines = ["day by day:"]
        for data in report.days where data.start >= today || calendar.isDate(data.start, inSameDayAs: today) {
            let label: String
            if calendar.isDate(data.start, inSameDayAs: today) {
                label = "today (\(shortDay.string(from: data.start)))"
            } else if calendar.isDate(data.start, inSameDayAs: tomorrow) {
                label = "tomorrow (\(shortDay.string(from: data.start)))"
            } else {
                label = shortDay.string(from: data.start)
            }
            var parts = ["\(label): \(range(data.low, data.high))", skyText(data.sky, chance: data.rainChance)]
            if let rain = rainUpTo(data.rainChance, total: data.precipitationMm) { parts.append(rain) }
            if let wind = data.windMaxKmh { parts.append("wind up to \(speed(wind))\(gusts(data.gustMaxKmh, over: wind))") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines
    }

    // MARK: Lines

    private func placeLine(_ place: WeatherPlace) -> String {
        let name = place.name ?? "name unavailable"
        switch place.source {
        case .named:
            return "\(name) (the place asked for)"
        case .current:
            return place.name == nil ? "the owner's current position (place name unavailable)" : "\(name) (where the owner is now)"
        case .lastKnown(let age):
            return "\(name) (the owner's last known position, \(Self.ageText(age)) old; no fresh location right now)"
        case .homeCity:
            return "\(name) (the owner's home city setting; their current location isn't available)"
        }
    }

    private func localTimeLine(phoneTimeZone: TimeZone) -> String {
        let stamp = "\(longDay.string(from: now)), \(time(now))"
        let difference = report.timeZone.secondsFromGMT(for: now) - phoneTimeZone.secondsFromGMT(for: now)
        guard difference != 0 else { return "local time: \(stamp)" }
        let hours = Double(abs(difference)) / 3600
        let amount = hours == hours.rounded() ? "\(Int(hours))" : String(format: "%.1f", hours)
        let unit = hours == 1 ? "hour" : "hours"
        return "local time there: \(stamp) (\(amount) \(unit) \(difference > 0 ? "ahead of" : "behind") the owner)"
    }

    private func nowLines() -> [String] {
        if let now = report.now {
            var line = "now: \(degrees(now.temperature))\(feels(now.feelsLike, vs: now.temperature)), \(now.sky.text)"
            if let wind = now.windKmh { line += ", wind \(speed(wind))\(gusts(now.gustKmh, over: wind))" }
            if let humidity = now.humidity { line += ", humidity \(percent(humidity))" }
            return [line]
        }
        if let current = hours(from: thisHour, to: nextHour).first { return ["now (this hour's forecast): " + hourLine(current)] }
        return []
    }

    private func hourLine(_ hour: WeatherReport.Hour) -> String {
        var line = "\(time(hour.time)) \(degrees(hour.temperature))\(feels(hour.feelsLike, vs: hour.temperature)), \(hour.sky.text)"
        if let chance = hour.rainChance { line += ", rain \(percent(chance))" }
        line += amount(hour.precipitationMm, prefix: hour.rainChance == nil ? ", rain " : " ", wrap: false)
        if let wind = hour.windKmh { line += ", wind \(speed(wind))\(gusts(hour.gustKmh, over: wind))" }
        if let uv = hour.uvIndex, uv >= 3 { line += ", UV \(Int(uv.rounded()))" }
        return line
    }

    private func dayLine(_ data: WeatherReport.Day, label: String) -> String {
        var parts = ["\(label): high \(data.high.map(degrees) ?? "?"), low \(data.low.map(degrees) ?? "?")",
                     skyText(data.sky, chance: data.rainChance)]
        if let rain = rainUpTo(data.rainChance, total: data.precipitationMm) { parts.append(rain) }
        if let wind = data.windMaxKmh { parts.append("wind up to \(speed(wind))\(gusts(data.gustMaxKmh, over: wind))") }
        if let uv = data.uvMax, uv >= 3 { parts.append("UV up to \(Int(uv.rounded()))") }
        if let sunrise = data.sunrise { parts.append("sunrise \(time(sunrise))") }
        if let sunset = data.sunset { parts.append("sunset \(time(sunset))") }
        return parts.joined(separator: ", ")
    }

    /// One part of a day in a line: "afternoon (12:00–18:00): 9 to 11°C, light rain, rain up to 80% (1.2 mm), …"
    private func partLine(_ name: String, start: Date, end: Date) -> String? {
        let rows = hours(from: start, to: end)
        guard !rows.isEmpty else { return nil }
        let temperatures = rows.map(\.temperature)
        var parts = ["\(name) (\(time(start))–\(time(end))): \(range(temperatures.min(), temperatures.max()))"]
        if let feels = rows.compactMap(\.feelsLike).min(), let low = temperatures.min(), feels < low - 1.5 {
            parts[0] += ", feels as low as \(degrees(feels))"
        }
        parts.append(dominantSky(rows))
        let total = rows.compactMap(\.precipitationMm).reduce(0, +)
        if let rain = rainUpTo(rows.compactMap(\.rainChance).max(), total: total) { parts.append(rain) }
        if let wind = rows.compactMap(\.windKmh).max() {
            parts.append("wind up to \(speed(wind))\(gusts(rows.compactMap(\.gustKmh).max(), over: wind))")
        }
        return parts.joined(separator: ", ")
    }

    /// When rain is likely in `rows`, so Claude can say "from about three" instead of reading every hour.
    private func rainLine(_ rows: [WeatherReport.Hour], label: String) -> String {
        let label = "rain summary for \(label)"
        guard !rows.isEmpty else { return "\(label): no forecast data" }
        let likely = rows.filter { ($0.rainChance ?? 0) >= 50 || ($0.precipitationMm ?? 0) >= 0.5 }
        let possible = rows.filter { ($0.rainChance ?? 0) >= 25 || ($0.precipitationMm ?? 0) >= 0.1 }
        let peak = rows.compactMap(\.rainChance).max().map(percent)
        let total = rows.compactMap(\.precipitationMm).reduce(0, +)
        let upTo = peak.map { ", up to \($0)" } ?? ""
        if !likely.isEmpty {
            return "\(label): \(precipitationWord(likely)) likely \(spans(likely))\(upTo), about \(millimetres(total)) in total"
        }
        if !possible.isEmpty {
            let totalText = total >= 0.1 ? ", about \(millimetres(total)) in total" : ""
            return "\(label): \(precipitationWord(possible)) possible \(spans(possible))\(upTo)\(totalText)"
        }
        return "\(label): dry" + (peak.map { ", rain chance at most \($0)" } ?? "")
    }

    // MARK: Pieces

    /// The wettest sky when rain is likely, otherwise the most common one.
    private func dominantSky(_ rows: [WeatherReport.Hour]) -> String {
        let wet = rows.filter { $0.sky.kind >= .rain && ($0.rainChance ?? 100) >= 40 }
        if let worst = wet.max(by: { ($0.sky.kind, $0.rainChance ?? 0) < ($1.sky.kind, $1.rainChance ?? 0) }) {
            return worst.sky.text
        }
        let counts = Dictionary(grouping: rows, by: { skyText($0.sky, chance: $0.rainChance) }).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "unknown"
    }

    private func precipitationWord(_ rows: [WeatherReport.Hour]) -> String {
        let snow = rows.contains { $0.sky.kind == .snow }
        let rain = rows.contains { $0.sky.kind == .rain || $0.sky.kind == .storm }
        if snow && rain { return "rain or snow" }
        if snow || (!rain && (rows.map(\.temperature).max() ?? 10) <= 0.5) { return "snow" }
        return "rain"
    }

    /// "15:00–18:00 and 21:00–23:00"
    private func spans(_ rows: [WeatherReport.Hour]) -> String {
        var runs: [(start: Date, end: Date)] = []
        for row in rows.sorted(by: { $0.time < $1.time }) {
            let end = row.time.addingTimeInterval(3600)
            if let last = runs.last, abs(last.end.timeIntervalSince(row.time)) < 60 {
                runs[runs.count - 1].end = end
            } else {
                runs.append((row.time, end))
            }
        }
        if runs.count > 3, let first = runs.first, let last = runs.last {
            return "on and off from \(time(first.start)) to \(time(last.end))"
        }
        return runs.map { "\(time($0.start))–\(time($0.end))" }.joined(separator: " and ")
    }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°C" }

    private func range(_ low: Double?, _ high: Double?) -> String {
        switch (low.map { Int($0.rounded()) }, high.map { Int($0.rounded()) }) {
        case let (low?, high?) where low == high: return "\(low)°C"
        case let (low?, high?): return "\(low) to \(high)°C"
        case let (low?, nil): return "low \(low)°C"
        case let (nil, high?): return "high \(high)°C"
        default: return "temperature unknown"
        }
    }

    private func feels(_ feelsLike: Double?, vs temperature: Double) -> String {
        guard let feelsLike, abs(feelsLike - temperature) >= 1 else { return "" }
        return " (feels like \(degrees(feelsLike)))"
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// The sky in words, softened when it says rain or snow but the chance is low (the sky comes from one model
    /// run, the chance from many, so they can disagree).
    private func skyText(_ sky: WeatherReport.Sky, chance: Double?) -> String {
        guard sky.kind >= .rain, let chance, chance < 30 else { return sky.text }
        return chance < 10 ? "cloudy" : "cloudy, a little \(sky.kind == .snow ? "snow" : "rain") possible"
    }

    /// "rain up to 80% (1.2 mm)", "dry", or nothing when the chance is unknown.
    private func rainUpTo(_ chance: Double?, total: Double?) -> String? {
        guard let chance else { return nil }
        if chance < 10, (total ?? 0) < 0.1 { return "dry" }
        return "rain up to \(percent(chance))\(amount(total, prefix: " ", wrap: true))"
    }

    private func speed(_ value: Double) -> String { "\(Int(value.rounded())) km/h" }

    private func gusts(_ gust: Double?, over wind: Double) -> String {
        guard let gust, gust >= 30, gust >= wind + 10 else { return "" }
        return " gusting \(Int(gust.rounded()))"
    }

    private func millimetres(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f mm", value) : String(format: "%.1f mm", value)
    }

    /// Rain amount if there is any: " 0.8 mm", or " (0.8 mm)" with `wrap`.
    private func amount(_ value: Double?, prefix: String, wrap: Bool) -> String {
        guard let value, value >= 0.1 else { return "" }
        return wrap ? "\(prefix)(\(millimetres(value)))" : "\(prefix)\(millimetres(value))"
    }

    private func time(_ date: Date) -> String { clock.string(from: date) }

    private func partLabel(_ part: WeatherQuery.PartOfDay, today: Bool) -> String {
        guard today else { return part.rawValue }
        return part == .night ? "tonight" : "this \(part.rawValue)"
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes <= 1 { return "about a minute" }
        if minutes < 90 { return "about \(minutes) minutes" }
        let hours = Int((seconds / 3600).rounded())
        return hours == 1 ? "about an hour" : "about \(hours) hours"
    }

    // MARK: Time

    private var today: Date { calendar.startOfDay(for: now) }
    private var tomorrow: Date { at(hour: 24, on: today) }
    private var thisHour: Date { calendar.dateInterval(of: .hour, for: now)?.start ?? now }
    private var nextHour: Date { hour(after: thisHour, 1) }

    private func hour(after date: Date, _ count: Int) -> Date { date.addingTimeInterval(TimeInterval(count) * 3600) }

    /// `hour` o'clock on the day starting at `dayStart`; 24 and above run into the next day. DST-safe.
    private func at(hour: Int, on dayStart: Date) -> Date {
        let base = calendar.date(byAdding: .day, value: hour / 24, to: dayStart) ?? dayStart
        return calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: base) ?? base
    }

    private func window(_ part: WeatherQuery.PartOfDay, on dayStart: Date) -> (Date, Date) {
        (at(hour: part.hours.start, on: dayStart), at(hour: part.hours.end, on: dayStart))
    }

    private func dayStart(_ day: WeatherQuery.Day) -> Date? {
        switch day {
        case .today:
            return today
        case .tomorrow:
            return tomorrow
        case .date(let year, let month, let date):
            let components = DateComponents(year: year, month: month, day: date)
            guard components.isValidDate(in: calendar), let found = calendar.date(from: components) else { return nil }
            return calendar.startOfDay(for: found)
        case .weekday(let weekday):
            let ahead = (weekday - calendar.component(.weekday, from: now) + 7) % 7
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }
    }

    private func hours(from start: Date, to end: Date) -> [WeatherReport.Hour] {
        report.hours.filter { $0.time >= start && $0.time < end }
    }

    private func day(at start: Date) -> WeatherReport.Day? {
        report.days.first { calendar.isDate($0.start, inSameDayAs: start) }
    }
}
