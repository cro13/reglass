import CoreLocation
import Foundation
import MapKit

/// Place names to coordinates ("Lyon" → Lyon, France) and back, with MapKit's geocoder (iOS 26). Results are
/// kept in memory for this run only. Names come back in English, for the assistant's English voice.
@MainActor
final class PlaceResolver {
    static let shared = PlaceResolver()

    struct Place: Sendable {
        var latitude: Double
        var longitude: Double
        /// "Lyon, France"
        var name: String
        /// "Lyon"
        var shortName: String
        var timeZone: TimeZone?
    }

    enum Failure: Error {
        case notFound
        /// No network, or MapKit didn't answer in time.
        case unreachable
    }

    private var named: [String: Place] = [:]
    private var nearby: [String: Place] = [:]
    private static let locale = Locale(identifier: "en_GB")

    /// The best match for a typed or spoken place name.
    func place(named text: String) async throws -> Place {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = named[key] { return cached }
        guard let request = MKGeocodingRequest(addressString: text) else { throw Failure.notFound }
        request.preferredLocale = Self.locale
        let items: [MKMapItem]
        do {
            guard let found = try await Deadline.run(seconds: 4, { try await request.mapItems }) else {
                request.cancel()
                throw Failure.unreachable
            }
            items = found
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw Failure.notFound
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            throw Failure.notFound
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable
        }
        guard let item = items.first, let place = Self.place(from: item, fallbackName: text) else { throw Failure.notFound }
        named[key] = place
        return place
    }

    /// The town or city at a position, or nil if the lookup fails. Cached per kilometre or so.
    func place(near location: CLLocation) async -> Place? {
        let key = String(format: "%.2f,%.2f", location.coordinate.latitude, location.coordinate.longitude)
        if let cached = nearby[key] { return cached }
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Self.locale
        guard let items = try? await Deadline.run(seconds: 3, { try await request.mapItems }) else {
            request.cancel()
            return nil
        }
        guard let item = items.first, var place = Self.place(from: item, fallbackName: nil) else { return nil }
        // Keep the fix's own coordinates: the map item may be the town centre.
        place.latitude = location.coordinate.latitude
        place.longitude = location.coordinate.longitude
        nearby[key] = place
        return place
    }

    private static func place(from item: MKMapItem, fallbackName: String?) -> Place? {
        let address = item.addressRepresentations
        let city = address?.cityName
        // A town's own name for towns; a landmark's name ("Matterhorn") when that's what was asked for.
        let short = (fallbackName == nil ? city : nil) ?? item.name ?? city ?? fallbackName
        guard let short, !short.isEmpty else { return nil }
        var full = address?.cityWithContext(.full) ?? short
        if !full.localizedCaseInsensitiveContains(short) { full = "\(short), \(full)" }
        let coordinate = item.location.coordinate
        return Place(latitude: coordinate.latitude, longitude: coordinate.longitude, name: full, shortName: short,
                     timeZone: item.timeZone)
    }
}

/// The owner's home city: where the weather is for when ReGlass can't tell where they are. Geocoded once when saved.
@MainActor
final class HomeCityStore: ObservableObject {
    static let shared = HomeCityStore()

    struct City: Codable, Equatable {
        var name: String
        var shortName: String
        var latitude: Double
        var longitude: Double
        var timeZoneID: String?
    }

    @Published private(set) var city: City?

    private static let key = "reglass.weather.homeCity"

    private init() {
        city = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(City.self, from: $0) }
    }

    func save(_ place: PlaceResolver.Place) {
        city = City(name: place.name, shortName: place.shortName, latitude: place.latitude, longitude: place.longitude,
                    timeZoneID: place.timeZone?.identifier)
        if let data = try? JSONEncoder().encode(city) { UserDefaults.standard.set(data, forKey: Self.key) }
        GlassesController.shared.log.add("Weather: home city set")
    }

    func remove() {
        city = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        GlassesController.shared.log.add("Weather: home city removed")
    }
}

/// Runs a MainActor operation with a time limit. Returns nil if `seconds` pass first; the operation is then cancelled
/// and left to finish on its own, so an API that ignores cancellation can't hold the caller.
@MainActor
enum Deadline {
    static func run<T>(seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        let gate = DeadlineGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
                gate.continuation = continuation
                gate.work = Task { @MainActor in
                    do {
                        gate.finish(.success(try await operation()))
                    } catch {
                        gate.finish(.failure(error))
                    }
                }
                gate.timer = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    if !Task.isCancelled { gate.finish(.success(nil)) }
                }
            }
        } onCancel: {
            Task { @MainActor in gate.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class DeadlineGate<T> {
    var continuation: CheckedContinuation<T?, Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<T?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}
