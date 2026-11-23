import CoreLocation
import Foundation
import ReGlassAssistant

/// Answers one weather question: where (a named place, a fix, the last fix, the home city), the forecast (kept ten
/// minutes per square kilometre or so), then the brief for Claude. Logs kinds and timings only, never places.
@MainActor
final class WeatherEngine {
    static let shared = WeatherEngine()

    private struct Cached {
        let report: WeatherReport
        let fetched: Date
    }

    private var cache: [String: Cached] = [:]
    private static let cacheLife: TimeInterval = 600
    /// A fix this recent is used as is, without asking iOS for a new one.
    private static let freshEnough: TimeInterval = 300
    /// The oldest fix used when no new one comes; its age goes into the brief.
    private static let oldestUsable: TimeInterval = 2 * 3600

    private static let hereWords: Set<String> = ["here", "current location", "my location", "where i am", "nearby",
                                                 "local", "current", "around here", "this place", "my area"]
    private static let homeWords: Set<String> = ["home", "my home", "at home", "home city", "my city"]

    func answer(_ query: WeatherQuery, context: ToolContext) async -> ToolResult {
        let started = Date()

        let resolved: WeatherPlace
        switch await resolvePlace(query.place) {
        case .success(let place):
            resolved = place
        case .failure(let problem):
            log("no answer (\(problem.logText)) after \(Self.seconds(since: started))")
            return .failure(problem.message, action: ToolAction(title: "Weather", detail: problem.actionDetail))
        }
        let located = Date()

        // Finding the place and the forecast share one budget inside the tool loop's 10 s limit, so a slow service
        // ends with its own sentence rather than "took too long".
        let deadline = started.addingTimeInterval(8.5)
        async let lookup = name(for: resolved)
        let forecast = await self.forecast(for: resolved, until: deadline)
        var place = resolved
        if let found = await lookup {
            place.name = found.name
            place.shortName = found.shortName
        }

        guard case .success(let fetched) = forecast else {
            if case .failure(let problem) = forecast {
                log("no answer (\(problem.logText)) after \(Self.seconds(since: started))")
                return .failure(problem.message, action: ToolAction(title: "Weather", detail: problem.actionDetail))
            }
            return .failure("The weather service didn't answer.")
        }

        let brief = WeatherBrief(report: fetched.report, now: context.date)
        let placeLabel = place.shortName ?? (place.source == .current ? "Here" : "Weather")
        switch brief.facts(place: place, query: query, phoneTimeZone: context.timeZone) {
        case .success(let text):
            log("\(Self.kind(of: place.source)) in \(Self.seconds(since: started, until: located)), "
                + "\(fetched.report.source) \(fetched.cached ? "cached" : "in " + Self.seconds(since: located)), "
                + "\(Self.seconds(since: started)) total")
            return .success(text, action: ToolAction(title: "Weather", detail: "\(placeLabel) · \(query.label)"))
        case .failure(let failure):
            log("no answer (day out of range)")
            return .failure(failure.message, action: ToolAction(title: "Weather", detail: "\(placeLabel) · \(query.label)"))
        }
    }

    // MARK: Where

    private func resolvePlace(_ text: String?) async -> Result<WeatherPlace, Problem> {
        guard let text else { return await resolveHere() }
        let word = text.lowercased()
        if Self.hereWords.contains(word) { return await resolveHere() }
        if Self.homeWords.contains(word) {
            guard let home = HomeCityStore.shared.city else { return .failure(.noHomeCity) }
            return .success(home.weatherPlace)
        }
        do {
            let found = try await PlaceResolver.shared.place(named: text)
            return .success(WeatherPlace(latitude: found.latitude, longitude: found.longitude, name: found.name,
                                         shortName: found.shortName, timeZone: found.timeZone, source: .named))
        } catch PlaceResolver.Failure.notFound {
            return .failure(.placeNotFound(text))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.placeLookupDown)
        }
    }

    /// A fix if iOS allows one now, else a recent enough last fix, else the home city.
    private func resolveHere() async -> Result<WeatherPlace, Problem> {
        let location = LocationService.shared
        if let known = location.lastKnownLocation, known.age < Self.freshEnough, Self.usable(known.location) {
            return .success(.here(known.location, source: .current))
        }
        var failure: LocationService.Failure?
        if location.canLocateNow {
            do {
                let fix = try await location.currentLocation(accuracy: kCLLocationAccuracyKilometer, timeout: .seconds(4))
                return .success(.here(fix, source: .current))
            } catch let error as LocationService.Failure {
                failure = error
            } catch {
                return .failure(.cancelled)
            }
        } else {
            failure = location.access.allowsLocation ? .needsAlways : .notAllowed
        }
        if let known = location.lastKnownLocation, known.age <= Self.oldestUsable, Self.usable(known.location) {
            return .success(.here(known.location, source: known.age < 600 ? .current : .lastKnown(known.age)))
        }
        if let home = HomeCityStore.shared.city { return .success(home.weatherPlace) }
        return .failure(.noLocation(location.access, failure))
    }

    private static func usable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 10_000
    }

    /// The town at a fix, for the brief and Chats. Named places and the home city already have one.
    private func name(for place: WeatherPlace) async -> PlaceResolver.Place? {
        switch place.source {
        case .named, .homeCity: return nil
        case .current, .lastKnown:
            return await PlaceResolver.shared.place(near: CLLocation(latitude: place.latitude, longitude: place.longitude))
        }
    }

    // MARK: Forecast

    private func forecast(for place: WeatherPlace,
                          until deadline: Date) async -> Result<(report: WeatherReport, cached: Bool), Problem> {
        let key = String(format: "%.2f,%.2f", place.latitude, place.longitude)
        if let hit = cache[key], Date().timeIntervalSince(hit.fetched) < Self.cacheLife {
            return .success((hit.report, true))
        }
        for source in WeatherSources.ordered {
            do {
                let report = try await Deadline.run(seconds: max(1.5, min(8, deadline.timeIntervalSinceNow))) {
                    try await source.forecast(latitude: place.latitude, longitude: place.longitude, timeZone: place.timeZone)
                }
                guard let report else {
                    log("\(source.name) timed out")
                    continue
                }
                cache = cache.filter { Date().timeIntervalSince($0.value.fetched) < Self.cacheLife }
                cache[key] = Cached(report: report, fetched: Date())
                return .success((report, false))
            } catch {
                if Task.isCancelled || error is CancellationError { return .failure(.cancelled) }
                log("\(source.name) failed (\(Self.describe(error)))")
            }
        }
        return .failure(.forecastDown)
    }

    // MARK: Problems

    private enum Problem: Error {
        case placeNotFound(String)
        case placeLookupDown
        case noHomeCity
        case noLocation(LocationService.Access, LocationService.Failure?)
        case forecastDown
        case cancelled

        /// For Claude: one plain sentence it can relay or act on.
        var message: String {
            switch self {
            case .placeNotFound(let text):
                return "No place called \"\(text)\" was found. Ask which town or city they mean, with its country."
            case .placeLookupDown:
                return "Looking up that place failed, probably because there's no internet connection right now."
            case .noHomeCity:
                return "There's no home city set in ReGlass. Ask which town or city they mean."
            case .noLocation(.whileUsing, _):
                return "ReGlass can't get the location while the iPhone is locked, because location is set to While Using, "
                    + "and there's no recent position or home city. Ask which town or city they mean."
            case .noLocation(.always, _):
                return "The iPhone couldn't find its location just now, and there's no home city set. "
                    + "Ask which town or city they mean."
            case .noLocation:
                return "Location is off for ReGlass and there's no home city set. Ask which town or city they mean."
            case .forecastDown:
                return "The weather service didn't answer, probably because there's no internet connection right now."
            case .cancelled:
                return "Cancelled."
            }
        }

        var logText: String {
            switch self {
            case .placeNotFound: return "place not found"
            case .placeLookupDown: return "geocoder unreachable"
            case .noHomeCity: return "home asked, no home city"
            case .noLocation(let access, let failure):
                return "no location: access \(access), \(failure.map { "\($0)" } ?? "no fix tried"), no home city"
            case .forecastDown: return "every source failed"
            case .cancelled: return "cancelled"
            }
        }

        /// For the Chats line.
        var actionDetail: String {
            switch self {
            case .placeNotFound: return "Place not found"
            case .placeLookupDown, .forecastDown: return "No connection"
            case .noHomeCity, .noLocation: return "Location unknown"
            case .cancelled: return "Stopped"
            }
        }
    }

    // MARK: Log

    private func log(_ text: String) {
        GlassesController.shared.log.add("Weather: \(text)")
    }

    private static func kind(of source: WeatherPlace.Source) -> String {
        switch source {
        case .named: return "named place"
        case .current: return "here"
        case .lastKnown(let age): return "last fix \(Int(age / 60)) min old"
        case .homeCity: return "home city"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? WeatherSourceError {
            switch error {
            case .http(let status): return "HTTP \(status)"
            case .unreadable: return "unreadable reply"
            }
        }
        if let error = error as? URLError { return "network \(error.code.rawValue)" }
        return String(describing: type(of: error))
    }

    private static func seconds(since start: Date, until end: Date = Date()) -> String {
        String(format: "%.1f s", end.timeIntervalSince(start))
    }
}

private extension WeatherPlace {
    static func here(_ location: CLLocation, source: Source) -> WeatherPlace {
        WeatherPlace(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                     name: nil, shortName: nil, timeZone: nil, source: source)
    }
}

private extension HomeCityStore.City {
    var weatherPlace: WeatherPlace {
        WeatherPlace(latitude: latitude, longitude: longitude, name: name, shortName: shortName,
                     timeZone: timeZoneID.flatMap(TimeZone.init(identifier:)), source: .homeCity)
    }
}

/// `get_weather`: Claude's one weather tool.
struct GetWeatherTool: AssistantTool {
    var definition: ToolDefinition { Self.toolDefinition }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        guard let query = WeatherQuery(input: input) else {
            return .failure("The weather request wasn't understood. Give \"when\" as now, next_hours, today, tonight, "
                + "tomorrow, week, or day with a date.", action: ToolAction(title: "Weather", detail: "Not understood"))
        }
        return await WeatherEngine.shared.answer(query, context: context)
    }

    private static let toolDefinition = ToolDefinition(
        name: "get_weather",
        description: """
        The weather forecast for where the owner is now or for any named town: current conditions, hour by hour \
        temperature, feels-like, rain chance and amount, wind and UV, the day's high and low, sunrise and sunset, \
        up to 7 days ahead. Use it for every weather question (rain, umbrella, jacket, cold, heat, snow, wind, \
        sunrise, sunset) instead of web search. Leave out place for where the owner is; otherwise pass the town or \
        city, with its country when it could be ambiguous ("Paris, France"). Pick when from the question and narrow \
        it with part_of_day when they name one. Examples: "will it rain this afternoon" → when today, part_of_day \
        afternoon; "do I need a jacket tonight" → when tonight; "what about tomorrow in Lyon" → when tomorrow, place \
        Lyon; "on Friday" → when day, date Friday's date. Returns short metric facts: the place used and how it was \
        found, the local time there, then the numbers and a rain summary. Answer in one or two sentences with only \
        what was asked: give rain as a time window, not hour by hour, and judge a jacket or umbrella from the \
        feels-like temperature, wind and rain chance. Say the place's name when it was asked for or the place line \
        says it isn't the owner's current position. If the service didn't answer, you may use web search instead.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "place": [
                    "type": "string",
                    "description": "A town or city, with its country if it could be ambiguous. Leave out for where the owner is now.",
                ],
                "when": [
                    "type": "string",
                    "enum": ["now", "next_hours", "today", "tonight", "tomorrow", "day", "week"],
                    "description": .string("now: current conditions and the next few hours. next_hours: hour by hour "
                        + "for the next `hours` hours. today: the rest of today. tonight: this evening and overnight to "
                        + "06:00. tomorrow: tomorrow. day: the day in `date`. week: day by day for the next 7 days."),
                ],
                "part_of_day": [
                    "type": "string",
                    "enum": ["morning", "afternoon", "evening", "night"],
                    "description": .string("Narrows today, tomorrow or day: morning 06–12, afternoon 12–18, "
                        + "evening 18–24, night 18:00 to 06:00 the next morning."),
                ],
                "date": [
                    "type": "string",
                    "description": "YYYY-MM-DD, only with when = day, at most 7 days ahead.",
                ],
                "hours": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 24,
                    "description": "Only with when = next_hours. Default 3.",
                ],
            ],
            "required": ["when"],
            "additionalProperties": false,
        ]
    )
}
