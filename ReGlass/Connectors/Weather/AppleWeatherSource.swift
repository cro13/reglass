import CoreLocation
import SwiftUI
import WeatherKit

// Apple Weather (WeatherKit), ready but not in use: `WeatherSources.ordered` lists only Open-Meteo. WeatherKit needs
// the `com.apple.developer.weatherkit` entitlement and the WeatherKit service enabled for the App ID in the developer
// portal. Without them every call fails (and with the entitlement but no portal setup, signing can fail), so it
// stays off until that portal step is done.

/// Forecasts from Apple Weather. On any failure the next source in `WeatherSources.ordered` answers instead.
struct AppleWeatherSource: WeatherSource {
    let name = "Apple Weather"

    func forecast(latitude: Double, longitude: Double, timeZone: TimeZone?) async throws -> WeatherReport {
        let zone = timeZone ?? .current
        let calendar = WeatherBrief.englishCalendar(zone)
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 8, to: start) ?? start.addingTimeInterval(8 * 86_400)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let (current, hourly, daily) = try await WeatherService.shared.weather(
            for: location, including: .current, .hourly(startDate: start, endDate: end), .daily(startDate: start, endDate: end))

        let now = WeatherReport.Now(time: current.date, temperature: Self.celsius(current.temperature),
                                    feelsLike: Self.celsius(current.apparentTemperature),
                                    sky: Self.sky(current.condition, isDay: current.isDaylight),
                                    windKmh: Self.kmh(current.wind.speed), gustKmh: current.wind.gust.map(Self.kmh),
                                    humidity: current.humidity * 100)
        let hours = hourly.forecast.map { hour in
            WeatherReport.Hour(time: hour.date, temperature: Self.celsius(hour.temperature),
                               feelsLike: Self.celsius(hour.apparentTemperature),
                               sky: Self.sky(hour.condition, isDay: hour.isDaylight),
                               rainChance: hour.precipitationChance * 100,
                               precipitationMm: hour.precipitationAmount.converted(to: .millimeters).value,
                               windKmh: Self.kmh(hour.wind.speed), gustKmh: hour.wind.gust.map(Self.kmh),
                               uvIndex: Double(hour.uvIndex.value))
        }
        let days = daily.forecast.map { day in
            // The day's total from its hours: simpler than the per-type amounts and the same number.
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date.addingTimeInterval(86_400)
            let dayHours = hours.filter { $0.time >= day.date && $0.time < dayEnd }
            return WeatherReport.Day(start: day.date, high: Self.celsius(day.highTemperature), low: Self.celsius(day.lowTemperature),
                                     sky: Self.sky(day.condition, isDay: true),
                                     rainChance: day.precipitationChance * 100,
                                     precipitationMm: dayHours.isEmpty ? nil : dayHours.compactMap(\.precipitationMm).reduce(0, +),
                                     windMaxKmh: Self.kmh(day.wind.speed), gustMaxKmh: day.wind.gust.map(Self.kmh),
                                     uvMax: Double(day.uvIndex.value), sunrise: day.sun.sunrise, sunset: day.sun.sunset)
        }
        return WeatherReport(timeZone: zone, now: now, hours: hours, days: days, source: name)
    }

    private static func celsius(_ value: Measurement<UnitTemperature>) -> Double { value.converted(to: .celsius).value }
    private static func kmh(_ value: Measurement<UnitSpeed>) -> Double { value.converted(to: .kilometersPerHour).value }

    private static func sky(_ condition: WeatherCondition, isDay: Bool) -> WeatherReport.Sky {
        typealias Sky = WeatherReport.Sky
        switch condition {
        case .clear: return Sky(text: isDay ? "sunny" : "clear", kind: .dry)
        case .mostlyClear: return Sky(text: isDay ? "mostly sunny" : "mostly clear", kind: .dry)
        case .foggy, .haze, .smoky, .blowingDust: return Sky(text: condition.description.lowercased(), kind: .fog)
        case .drizzle, .rain, .heavyRain, .sunShowers, .freezingDrizzle, .freezingRain, .sleet, .hail:
            return Sky(text: condition.description.lowercased(), kind: .rain)
        case .snow, .heavySnow, .flurries, .sunFlurries, .blowingSnow, .blizzard, .wintryMix:
            return Sky(text: condition.description.lowercased(), kind: .snow)
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .tropicalStorm, .hurricane:
            return Sky(text: condition.description.lowercased(), kind: .storm)
        default:
            return Sky(text: condition.description.lowercased(), kind: .dry)
        }
    }
}

/// Apple's required credit while Apple Weather is in use: the Weather mark and the link to its other data sources.
struct AppleWeatherCredit: View {
    @State private var credit: (mark: URL, legal: URL)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let credit {
                AsyncImage(url: credit.mark) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(height: 14)
                .accessibilityLabel("Apple Weather")
                Link("Other data sources", destination: credit.legal)
                    .font(.footnote)
                    .tint(Theme.accent)
            }
        }
        .task {
            guard credit == nil, let attribution = try? await WeatherService.shared.attribution else { return }
            // ReGlass is always dark, so the mark made for dark backgrounds.
            credit = (attribution.combinedMarkDarkURL, attribution.legalPageURL)
        }
    }
}
