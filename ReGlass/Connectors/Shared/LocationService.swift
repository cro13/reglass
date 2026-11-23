import CoreLocation
import Foundation
import UIKit

// The iPhone's location for connectors (weather). One shared CLLocationManager owns
// iOS's permission flow (While Using, then the upgrade to Always) and one-shot fixes with a time limit.
//
// - Requests usually arrive while ReGlass is in the background with the iPhone locked. iOS only allows a new fix
//   there with Always; with While Using, `canLocateNow` is false and callers fall back to `lastKnownLocation`.
// - A feature that needs continuous tracking should run its own CLLocationManager:
//   permission is per app, so it can read `access` from here, but the delegate below belongs to one-shot fixes.
// - Privacy: places and coordinates never go to the activity log. Only states, ages and timings do.

@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    /// What iOS allows ReGlass.
    enum Access: Equatable {
        case notAsked, denied, restricted, whileUsing, always

        var allowsLocation: Bool { self == .whileUsing || self == .always }

        /// For settings rows, in the owner's words.
        var label: String {
            switch self {
            case .notAsked: return "Not allowed yet"
            case .denied: return "Off"
            case .restricted: return "Not allowed on this iPhone"
            case .whileUsing: return "While using ReGlass"
            case .always: return "Always"
            }
        }

        /// For the activity log.
        fileprivate var logName: String {
            switch self {
            case .notAsked: return "not asked"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .whileUsing: return "while using"
            case .always: return "always"
            }
        }
    }

    /// Why a fresh fix didn't come.
    enum Failure: Error, Equatable {
        /// Location is off for ReGlass (or never allowed).
        case notAllowed
        /// While Using only, and ReGlass is in the background (iPhone locked): iOS refuses new fixes.
        case needsAlways
        /// No fix within the time limit.
        case timedOut
        /// iOS couldn't work out where the iPhone is.
        case unavailable
    }

    /// A fix ReGlass or iOS already has.
    struct KnownLocation {
        let location: CLLocation
        /// Seconds since the fix was taken.
        var age: TimeInterval { max(0, -location.timestamp.timeIntervalSinceNow) }
    }

    @Published private(set) var access: Access
    /// False when the owner turned off Precise Location for ReGlass: fixes are then a few kilometres wide, which is
    /// fine for weather but not for anything that needs a street.
    @Published private(set) var isPrecise: Bool

    private let manager: CLLocationManager
    private var fixWaiters: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var fixStarted: Date?
    private var answerWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var newestFix: CLLocation?
    private var activeObserver: NSObjectProtocol?

    private override init() {
        let manager = CLLocationManager()
        self.manager = manager
        access = Self.access(for: manager.authorizationStatus)
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        // A coarse fix each time ReGlass comes to the foreground, so a later request from the pocket (where While
        // Using can't take a new fix) still has a recent position to fall back on.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInForeground() }
        }
    }

    // MARK: State

    /// Whether a fresh fix can be taken right now: Always, or While Using with ReGlass on screen.
    var canLocateNow: Bool {
        switch access {
        case .always: return true
        case .whileUsing: return UIApplication.shared.applicationState != .background
        case .notAsked, .denied, .restricted: return false
        }
    }

    /// The newest fix ReGlass or iOS has, however old (see `age`), or nil.
    var lastKnownLocation: KnownLocation? {
        let candidates = [newestFix, access.allowsLocation ? manager.location : nil].compactMap { $0 }
        return candidates.max { $0.timestamp < $1.timestamp }.map(KnownLocation.init)
    }

    // MARK: Permission

    /// The owner tapped "Allow location": asks for While Using, then right away for Always, as far as iOS still
    /// shows its prompts. When iOS won't ask again (turned off before, or the Always prompt already used), opens
    /// ReGlass's page in iOS Settings instead. Runs in the foreground.
    func setUp() async {
        switch access {
        case .notAsked:
            await requestWhenInUse()
            guard access == .whileUsing else { return }
            // Let the first prompt finish leaving before the second one comes in.
            try? await Task.sleep(for: .milliseconds(700))
            await requestAlways()
        case .whileUsing:
            if await !requestAlways() { openSettings() }
        case .denied, .restricted:
            openSettings()
        case .always:
            break
        }
    }

    /// Shows iOS's location prompt if it's never been answered, and returns once the owner has answered it.
    func requestWhenInUse() async {
        guard access == .notAsked else { return }
        manager.requestWhenInUseAuthorization()
        await waitForAnswer(limit: .seconds(300))
    }

    /// Asks iOS to upgrade While Using to Always. iOS shows this prompt at most once; after that only iOS Settings
    /// can change it. Returns whether a prompt appeared (or Always is on now).
    @discardableResult
    func requestAlways() async -> Bool {
        guard access == .whileUsing else { return access == .always }
        // A system prompt makes ReGlass resign active. Watch for that before asking, so it can't be missed.
        let resigned = NotificationLatch(UIApplication.willResignActiveNotification)
        let returned = NotificationLatch(UIApplication.didBecomeActiveNotification)
        defer {
            resigned.stop()
            returned.stop()
        }
        manager.requestAlwaysAuthorization()
        let prompted = await resigned.wait(limit: .seconds(1.5))
        if prompted {
            _ = await returned.wait(limit: .seconds(300))
            // The authorization callback can land just after ReGlass is active again.
            try? await Task.sleep(for: .milliseconds(300))
        }
        GlassesController.shared.log.add("Location: Always prompt \(prompted ? "shown" : "not shown by iOS")")
        return prompted || access == .always
    }

    /// ReGlass's page in iOS Settings, where Location can be set to Always.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func waitForAnswer(limit: Duration) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            answerWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                self?.answerWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    // MARK: Fixes

    /// One fresh fix, or a `Failure` within `timeout`. Works in the background only with Always. `accuracy` is
    /// what iOS aims for (`kCLLocationAccuracyKilometer` is plenty for weather and comes fastest). Concurrent
    /// callers share one request. Throws `CancellationError` if the calling task is cancelled.
    func currentLocation(accuracy: CLLocationAccuracy = kCLLocationAccuracyHundredMeters,
                         timeout: Duration = .seconds(5)) async throws -> CLLocation {
        guard access.allowsLocation else { throw Failure.notAllowed }
        guard canLocateNow else { throw Failure.needsAlways }
        let id = UUID()
        let started = Date()
        do {
            let fix = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
                    fixWaiters[id] = continuation
                    startFix(accuracy: accuracy)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.finishWaiter(id, with: .failure(Failure.timedOut))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishWaiter(id, with: .failure(CancellationError())) }
            }
            GlassesController.shared.log.add("Location: fix in \(Self.seconds(since: started))")
            return fix
        } catch let failure as Failure {
            GlassesController.shared.log.add("Location: no fix (\(failure)) after \(Self.seconds(since: started))")
            throw failure
        }
    }

    private func startFix(accuracy: CLLocationAccuracy) {
        // The finest accuracy any waiter asked for wins (smaller numbers are finer).
        if fixStarted == nil || accuracy < manager.desiredAccuracy { manager.desiredAccuracy = accuracy }
        // One request at a time; restart one that never answered.
        if let fixStarted, Date().timeIntervalSince(fixStarted) < 15 { return }
        fixStarted = Date()
        manager.requestLocation()
    }

    private func finishWaiter(_ id: UUID, with result: Result<CLLocation, Error>) {
        fixWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishAllWaiters(with result: Result<CLLocation, Error>) {
        let waiters = fixWaiters
        fixWaiters.removeAll()
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    private func refreshInForeground() {
        guard access.allowsLocation, fixStarted == nil else { return }
        if let known = lastKnownLocation, known.age < 600 { return }
        startFix(accuracy: kCLLocationAccuracyKilometer)
    }

    // MARK: Delegate events

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus, precise: Bool) {
        let new = Self.access(for: status)
        if isPrecise != precise { isPrecise = precise }
        if new != access {
            access = new
            GlassesController.shared.log.add("Location: access \(new.logName)\(precise ? "" : ", approximate")")
            // Deferred: this can fire while the registry itself is still being built.
            Task { @MainActor in ConnectorRegistry.shared.refresh() }
        }
        if new != .notAsked {
            let waiters = answerWaiters
            answerWaiters.removeAll()
            for continuation in waiters.values { continuation.resume() }
        }
        if !new.allowsLocation {
            fixStarted = nil
            finishAllWaiters(with: .failure(Failure.notAllowed))
        }
    }

    fileprivate func delivered(_ location: CLLocation) {
        newestFix = location
        fixStarted = nil
        finishAllWaiters(with: .success(location))
    }

    fileprivate func failed(_ code: CLError.Code?) {
        fixStarted = nil
        finishAllWaiters(with: .failure(code == .denied ? Failure.notAllowed : Failure.unavailable))
    }

    private static func access(for status: CLAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: return .notAsked
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .always
        case .authorizedWhenInUse: return .whileUsing
        @unknown default: return .denied
        }
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(start))
    }
}

// The manager was made on the main thread, so iOS calls its delegate there.
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        MainActor.assumeIsolated { self.authorizationChanged(status, precise: precise) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { self.delivered(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated { self.failed(code) }
    }
}

/// Remembers whether a notification was posted since it was made, and lets one caller wait for it with a limit.
@MainActor
private final class NotificationLatch {
    private var fired = false
    private var token: NSObjectProtocol?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    /// True as soon as the notification has been posted; false if `limit` passes first.
    func wait(limit: Duration) async -> Bool {
        if fired { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                self?.resume(false)
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        resume(false)
    }

    private func fire() {
        fired = true
        resume(true)
    }

    private func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
