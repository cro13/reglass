import Foundation

/// Somewhere forecasts come from.
protocol WeatherSource: Sendable {
    /// For the activity log and the brief: "Open-Meteo".
    var name: String { get }
    /// About 8 days from local midnight today, current conditions included. `timeZone` is the place's when the
    /// geocoder knew it; a source that reports its own (Open-Meteo) uses that instead.
    func forecast(latitude: Double, longitude: Double, timeZone: TimeZone?) async throws -> WeatherReport
}

enum WeatherSourceError: Error {
    case http(Int)
    case unreadable
}

/// Which sources ReGlass uses, in order: if the first fails, the next is tried.
///
/// Open-Meteo needs no key, account or entitlement, so it works on any build. To use Apple Weather first (once
/// WeatherKit is enabled for the app in the developer portal and `com.apple.developer.weatherkit` is in
/// project.yml), put `AppleWeatherSource()` before `OpenMeteoSource()`.
enum WeatherSources {
    static let ordered: [any WeatherSource] = [OpenMeteoSource()]

    /// Whether Apple Weather is in use, so its mark and legal link must show in Settings.
    static var usesAppleWeather: Bool { ordered.contains { $0 is AppleWeatherSource } }
    static var usesOpenMeteo: Bool { ordered.contains { $0 is OpenMeteoSource } }
}
