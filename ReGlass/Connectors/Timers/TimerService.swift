import Foundation
import ReGlassKit
import UIKit

/// ReGlass's timers. This iPhone keeps the truth: every running timer (id, label, length, start), saved so it survives
/// ReGlass being relaunched. The glasses get a copy through `GlassesConnection.timers` and chime by themselves; ReGlassKit
/// keeps that copy in step (every change, every reconnect, after a voice turn).
///
/// When a timer ends, the voice says what it was for, exactly once:
/// - when the glasses send a timer alert, match it by the alert's ID or by due time
/// - safety net: no alert within `alertGrace` of the due time (glasses restarted, out of range, folded): ReGlass
///   announces it anyway, on the glasses or else through the iPhone;
/// - glasses not connected: a phone-only timer, announced at its due time through the iPhone.
/// The iPhone's own check needs ReGlass running: it is while the glasses are connected (the assistant's background
/// audio). A timer that ended while iOS had ReGlass suspended is announced as soon as ReGlass runs again, saying how long
/// ago; after `staleAfter` it's dropped.
///
/// The activity log gets counts and states only, never labels.
@MainActor
final class TimerService {
    static let shared = TimerService()

    struct Timer: Codable, Equatable, Identifiable {
        let id: UUID
        /// What it's for, as the user said it ("food"); nil for a plain timer.
        let label: String?
        /// What the voice says when it ends, written by Claude when it was set; nil for the standard line.
        let announcement: String?
        let seconds: Int
        let start: Date

        var due: Date { start.addingTimeInterval(TimeInterval(seconds)) }
        var glassesID: String { id.uuidString.lowercased() }
        func secondsLeft(at now: Date) -> Int { max(0, Int(due.timeIntervalSince(now).rounded(.up))) }
    }

    struct Added {
        let timer: Timer
        /// It went to the glasses (now, or once the voice turn ends); false: phone-only.
        let onGlasses: Bool
        let running: Int
    }

    enum AddProblem: Error {
        case tooMany
    }

    enum Cancelled {
        case cancelled([Timer])
        /// Nothing is running.
        case nothingRunning
        /// Nothing matched what was asked for.
        case noMatch
        /// More than one timer could be meant; nothing was cancelled.
        case whichOne([Timer])
    }

    /// Running timers, soonest first.
    private(set) var timers: [Timer] = []
    /// Timers that ended or were cancelled lately (a late alert for one is ignored, never announced twice).
    private var finished: [(id: UUID, due: Date)] = []
    private var connection: GlassesConnection?
    private var alertsTask: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    /// The glasses hold eight; ReGlass allows as many.
    static let maxTimers = 8
    nonisolated static let maxSeconds = 86_400
    /// After its due time, how long a timer on the glasses gets to report its chime before ReGlass announces anyway.
    static let alertGrace: TimeInterval = 4
    /// An alert that doesn't name its timer belongs to the timer due closest before it, within this.
    static let alertMatchWindow: TimeInterval = 8
    /// The glasses' clock can run slightly ahead of the iPhone's: an alert may come this long before the due time.
    static let alertEarliness: TimeInterval = 1.5
    /// A timer that ended longer ago than this (ReGlass wasn't running) isn't announced.
    static let staleAfter: TimeInterval = 10 * 60

    private init() {
        // Nothing here may reach AssistantController or GlassesController: this can run inside their own set-up.
        timers = Self.load().sorted { $0.due < $1.due }
        Task { @MainActor [weak self] in self?.started() }
    }

    private func started() {
        if !timers.isEmpty { log("Timers: \(timers.count) restored") }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        reschedule()
    }

    // MARK: The glasses (GlassesController)

    /// A live connection started: its timers get the list, and its alerts come here.
    func attach(_ connection: GlassesConnection) {
        guard self.connection !== connection else { return }
        detach()
        self.connection = connection
        let alerts = connection.timers.alerts()
        alertsTask = Task { [weak self] in
            for await alert in alerts { self?.glassesRang(alert) }
        }
        syncGlasses()
        reschedule()
    }

    /// The live connection is going away.
    func detach() {
        alertsTask?.cancel()
        alertsTask = nil
        guard connection != nil else { return }
        connection = nil
        reschedule()
    }

    // MARK: The tools

    /// `requestedAt`: when the owner asked (the timer counts from then, within the last half minute).
    func add(seconds: Int, label: String?, announcement: String?, requestedAt: Date) -> Result<Added, AddProblem> {
        guard timers.count < Self.maxTimers else { return .failure(.tooMany) }
        let now = Date()
        let start = min(now, max(requestedAt, now.addingTimeInterval(-30)))
        let timer = Timer(id: UUID(), label: label, announcement: announcement,
                          seconds: min(max(seconds, 1), Self.maxSeconds), start: start)
        timers.append(timer)
        timers.sort { $0.due < $1.due }
        save()
        syncGlasses()
        reschedule()
        let onGlasses = glassesCanRing
        log("Timers: set (\(timers.count) running, \(onGlasses ? "on the glasses" : "phone only: glasses not connected"))")
        return .success(Added(timer: timer, onGlasses: onGlasses, running: timers.count))
    }

    /// `label` and `seconds` narrow the choice; `all` cancels every timer. With neither, the only timer.
    func cancel(label: String?, seconds: Int?, all: Bool) -> Cancelled {
        guard !timers.isEmpty else { return .nothingRunning }
        var candidates = timers
        if !all {
            if let label, !TimerSpeech.matchKey(label).isEmpty {
                let key = TimerSpeech.matchKey(label)
                let exact = candidates.filter { $0.label.map(TimerSpeech.matchKey) == key }
                candidates = !exact.isEmpty ? exact : candidates.filter { timer in
                    guard let own = timer.label.map(TimerSpeech.matchKey), !own.isEmpty else { return false }
                    return own.contains(key) || key.contains(own)
                }
            }
            if let seconds { candidates = candidates.filter { abs($0.seconds - seconds) <= 1 } }
            if candidates.isEmpty { return .noMatch }
            if candidates.count > 1 { return .whichOne(candidates) }
        }
        let ids = Set(candidates.map(\.id))
        timers.removeAll { ids.contains($0.id) }
        for timer in candidates { remember(timer) }
        save()
        syncGlasses()
        reschedule()
        log("Timers: \(candidates.count) cancelled (\(timers.count) running)")
        return .cancelled(candidates)
    }

    // MARK: Ending

    private func glassesRang(_ alert: GlassesTimerAlert) {
        if let id = alert.id {
            guard let timer = timers.first(where: { $0.glassesID == id }) else {
                log("Timers: the glasses rang a timer that already ended or was cancelled")
                return
            }
            finish(timer, rungByGlasses: true)
            return
        }
        // No id in the alert: the timer due closest before it (a recently ended one included, so a late alert for
        // that one doesn't take the next timer).
        let window = (alert.at.addingTimeInterval(-Self.alertMatchWindow))...(alert.at.addingTimeInterval(Self.alertEarliness))
        let running = timers.filter { window.contains($0.due) }.map { (id: $0.id, due: $0.due) }
        let ended = finished.filter { window.contains($0.due) }
        guard let closest = (running + ended).min(by: { abs($0.due.timeIntervalSince(alert.at)) < abs($1.due.timeIntervalSince(alert.at)) }),
              let timer = timers.first(where: { $0.id == closest.id }) else {
            log("Timers: the glasses rang a timer ReGlass couldn't match (ignored)")
            return
        }
        finish(timer, rungByGlasses: true)
    }

    private func checkDue() {
        let now = Date()
        for timer in timers where deadline(for: timer) <= now {
            finish(timer, rungByGlasses: false)
        }
        reschedule()
    }

    private func finish(_ timer: Timer, rungByGlasses: Bool) {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }) else { return }
        timers.remove(at: index)
        remember(timer)
        save()
        reschedule()
        let late = Date().timeIntervalSince(timer.due)
        guard late < Self.staleAfter else {
            log("Timers: a timer ended \(Int(late / 60)) min ago while ReGlass wasn't running; not announced")
            syncGlasses()
            return
        }
        let line = TimerSpeech.doneLine(label: timer.label, announcement: timer.announcement, seconds: timer.seconds,
                                        lateBy: late)
        let source = rungByGlasses ? "the glasses rang it" : "ReGlass's own check"
        Task { [weak self] in
            let route = await AssistantController.shared.announce(line, phoneFallback: true)
            self?.log("Timers: timer done (\(source)); announcement: \(route)")
            // After the voice spoke (so a list sent now can't cut the chime short before it does).
            self?.syncGlasses()
        }
    }

    // MARK: Scheduling

    /// The glasses can chime a timer and report it: connected, with their assistant registered.
    private var glassesCanRing: Bool { connection != nil && AssistantController.shared.available }

    /// When ReGlass announces a timer itself if the glasses haven't reported it.
    private func deadline(for timer: Timer) -> Date {
        timer.due.addingTimeInterval(glassesCanRing ? Self.alertGrace : 0)
    }

    private func reschedule() {
        scheduler?.cancel()
        scheduler = nil
        guard let next = timers.map(deadline(for:)).min() else { return }
        scheduler = Task { [weak self] in
            let wait = next.timeIntervalSinceNow
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self?.checkDue()
        }
    }

    private func syncGlasses() {
        connection?.timers.set(timers.map {
            GlassesTimer(id: $0.glassesID, title: $0.label ?? "Timer", start: $0.start, duration: TimeInterval($0.seconds))
        })
    }

    private func remember(_ timer: Timer) {
        finished.append((timer.id, timer.due))
        if finished.count > 32 { finished.removeFirst(finished.count - 32) }
    }

    private func log(_ line: String) {
        GlassesController.shared.log.add(line)
    }

    // MARK: Storage

    /// Application Support/ReGlass/Timers/timers.json, readable after the first unlock (labels are content).
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ReGlass/Timers/timers.json", directoryHint: .notDirectory)
    }

    private static func load() -> [Timer] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Timer].self, from: data)) ?? []
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(timers).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log("Timers: couldn't save the timers (\(type(of: error)))")
        }
    }
}
