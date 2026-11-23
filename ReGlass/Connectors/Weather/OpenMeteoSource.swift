import Foundation

/// Forecasts from Open-Meteo (open-meteo.com): free for non-commercial use, no key, data under CC BY 4.0 (the
/// credit is in Weather's settings). Coordinates are sent rounded to about a kilometre.
struct OpenMeteoSource: WeatherSource {
    let name = "Open-Meteo"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func forecast(latitude: Double, longitude: Double, timeZone: TimeZone?) async throws -> WeatherReport {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,"
                + "wind_speed_10m,wind_gusts_10m,relative_humidity_2m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,apparent_temperature,weather_code,is_day,"
                + "precipitation_probability,precipitation,wind_speed_10m,wind_gusts_10m,uv_index"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,"
                + "precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,uv_index_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "8"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
        ]
        guard let url = components?.url else { throw WeatherSourceError.unreadable }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WeatherSourceError.http(status) }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw WeatherSourceError.unreadable }
        return try body.report(source: name)
    }

    // MARK: Response

    private struct Body: Decodable {
        struct Current: Decodable {
            let time: Int
            let temperature2m: Double?
            let apparentTemperature: Double?
            let weatherCode: Int?
            let isDay: Int?
            let windSpeed10m: Double?
            let windGusts10m: Double?
            let relativeHumidity2m: Double?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code"
                case isDay = "is_day"
                case windSpeed10m = "wind_speed_10m"
                case windGusts10m = "wind_gusts_10m"
                case relativeHumidity2m = "relative_humidity_2m"
            }
        }

        struct Hourly: Decodable {
            let time: [Int]
            let temperature2m: [Double?]?
            let apparentTemperature: [Double?]?
            let weatherCode: [Int?]?
            let isDay: [Int?]?
            let precipitationProbability: [Double?]?
            let precipitation: [Double?]?
            let windSpeed10m: [Double?]?
            let windGusts10m: [Double?]?
            let uvIndex: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case weatherCode = "weather_code"
                case isDay = "is_day"
                case precipitationProbability = "precipitation_probability"
                case precipitation
                case windSpeed10m = "wind_speed_10m"
                case windGusts10m = "wind_gusts_10m"
                case uvIndex = "uv_index"
            }
        }

        struct Daily: Decodable {
            let time: [Int]
            let weatherCode: [Int?]?
            let temperature2mMax: [Double?]?
            let temperature2mMin: [Double?]?
            let sunrise: [Int?]?
            let sunset: [Int?]?
            let precipitationSum: [Double?]?
            let precipitationProbabilityMax: [Double?]?
            let windSpeed10mMax: [Double?]?
            let windGusts10mMax: [Double?]?
            let uvIndexMax: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time, sunrise, sunset
                case weatherCode = "weather_code"
                case temperature2mMax = "temperature_2m_max"
                case temperature2mMin = "temperature_2m_min"
                case precipitationSum = "precipitation_sum"
                case precipitationProbabilityMax = "precipitation_probability_max"
                case windSpeed10mMax = "wind_speed_10m_max"
                case windGusts10mMax = "wind_gusts_10m_max"
                case uvIndexMax = "uv_index_max"
            }
        }

        let timezone: String?
        let utcOffsetSeconds: Int?
        let current: Current?
        let hourly: Hourly?
        let daily: Daily?

        enum CodingKeys: String, CodingKey {
            case timezone, current, hourly, daily
            case utcOffsetSeconds = "utc_offset_seconds"
        }

        func report(source: String) throws -> WeatherReport {
            let zone = timezone.flatMap(TimeZone.init(identifier:))
                ?? utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
                ?? .current

            var now: WeatherReport.Now?
            if let current, let temperature = current.temperature2m {
                now = WeatherReport.Now(time: date(current.time), temperature: temperature,
                                        feelsLike: current.apparentTemperature,
                                        sky: OpenMeteoSource.sky(current.weatherCode, isDay: current.isDay != 0),
                                        windKmh: current.windSpeed10m, gustKmh: current.windGusts10m,
                                        humidity: current.relativeHumidity2m)
            }

            var hours: [WeatherReport.Hour] = []
            if let hourly {
                for (index, time) in hourly.time.enumerated() {
                    guard let temperature = value(hourly.temperature2m, index) else { continue }
                    hours.append(WeatherReport.Hour(
                        time: date(time), temperature: temperature,
                        feelsLike: value(hourly.apparentTemperature, index),
                        sky: OpenMeteoSource.sky(value(hourly.weatherCode, index), isDay: value(hourly.isDay, index) != 0),
                        rainChance: value(hourly.precipitationProbability, index),
                        precipitationMm: value(hourly.precipitation, index),
                        windKmh: value(hourly.windSpeed10m, index), gustKmh: value(hourly.windGusts10m, index),
                        uvIndex: value(hourly.uvIndex, index)))
                }
            }

            var days: [WeatherReport.Day] = []
            if let daily {
                for (index, time) in daily.time.enumerated() {
                    days.append(WeatherReport.Day(
                        start: date(time),
                        high: value(daily.temperature2mMax, index), low: value(daily.temperature2mMin, index),
                        sky: OpenMeteoSource.sky(value(daily.weatherCode, index), isDay: true),
                        rainChance: value(daily.precipitationProbabilityMax, index),
                        precipitationMm: value(daily.precipitationSum, index),
                        windMaxKmh: value(daily.windSpeed10mMax, index), gustMaxKmh: value(daily.windGusts10mMax, index),
                        uvMax: value(daily.uvIndexMax, index),
                        sunrise: value(daily.sunrise, index).map(date), sunset: value(daily.sunset, index).map(date)))
                }
            }

            guard now != nil || !hours.isEmpty else { throw WeatherSourceError.unreadable }
            return WeatherReport(timeZone: zone, now: now, hours: hours, days: days, source: source)
        }

        private func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

        private func value<T>(_ list: [T?]?, _ index: Int) -> T? {
            guard let list, list.indices.contains(index) else { return nil }
            return list[index]
        }
    }

    // MARK: Weather codes

    /// WMO weather interpretation codes, as Open-Meteo documents them.
    static func sky(_ code: Int?, isDay: Bool) -> WeatherReport.Sky {
        typealias Sky = WeatherReport.Sky
        switch code {
        case 0: return Sky(text: isDay ? "sunny" : "clear", kind: .dry)
        case 1: return Sky(text: isDay ? "mostly sunny" : "mostly clear", kind: .dry)
        case 2: return Sky(text: "partly cloudy", kind: .dry)
        case 3: return Sky(text: "overcast", kind: .dry)
        case 45, 48: return Sky(text: "fog", kind: .fog)
        case 51: return Sky(text: "light drizzle", kind: .rain)
        case 53: return Sky(text: "drizzle", kind: .rain)
        case 55: return Sky(text: "heavy drizzle", kind: .rain)
        case 56, 57: return Sky(text: "freezing drizzle", kind: .rain)
        case 61: return Sky(text: "light rain", kind: .rain)
        case 63: return Sky(text: "rain", kind: .rain)
        case 65: return Sky(text: "heavy rain", kind: .rain)
        case 66, 67: return Sky(text: "freezing rain", kind: .rain)
        case 71: return Sky(text: "light snow", kind: .snow)
        case 73: return Sky(text: "snow", kind: .snow)
        case 75: return Sky(text: "heavy snow", kind: .snow)
        case 77: return Sky(text: "snow grains", kind: .snow)
        case 80: return Sky(text: "light showers", kind: .rain)
        case 81: return Sky(text: "showers", kind: .rain)
        case 82: return Sky(text: "heavy showers", kind: .rain)
        case 85: return Sky(text: "light snow showers", kind: .snow)
        case 86: return Sky(text: "heavy snow showers", kind: .snow)
        case 95: return Sky(text: "thunderstorms", kind: .storm)
        case 96, 99: return Sky(text: "thunderstorms with hail", kind: .storm)
        default: return Sky(text: "sky unknown", kind: .dry)
        }
    }
}
