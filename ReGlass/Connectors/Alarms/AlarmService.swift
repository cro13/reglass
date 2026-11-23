import AlarmKit
import Foundation
import SwiftUI
import UIKit

/// ReGlass's alarms: real iPhone alarms made with AlarmKit, so they ring through Silent mode and Focus, show on the
/// Lock Screen and need ReGlass neither open nor running. Snooze is nine minutes (the Live Activity in ReGlassWidgets
/// draws the countdown).
///
/// AlarmKit's list has no labels, so ReGlass keeps a small record per alarm (id → label, kind, schedule, created) in a
/// file readable after the first unlock. AlarmKit stays the truth: a record whose alarm has gone (rung and stopped,
/// cancelled from the Lock Screen) is dropped whenever AlarmKit's list arrives (`alarmUpdates`, and at launch).
///
/// The activity log gets counts and states only, never labels or times.
@MainActor
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    /// ReGlass's own note about one alarm.
    struct Record: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            /// The next time a time of day comes round (a relative schedule: follows the time zone).
            case next
            /// Weekly on some days.
            case weekly
            /// One fixed moment (a given date, or "in N minutes").
            case fixed
        }

        let id: UUID
        let label: String?
        let kind: Kind
        let time: AlarmClock.ClockTime?
        /// Calendar weekday numbers (1 = Sunday) for a weekly alarm.
        let days: [Int]
        /// When it first rings, as set.
        let fire: Date
        let created: Date
    }

    /// One alarm as ReGlass tells it: AlarmKit's state and schedule, with ReGlass's label.
    struct Entry: Identifiable, Equatable {
        enum State: String {
            case set, snoozed, ringing, paused
        }

        let id: UUID
        let label: String?
        let state: State
        /// The time of day it rings (relative schedules).
        let time: AlarmClock.ClockTime?
        /// Weekly days (1 = Sunday); empty for a one-off.
        let days: [Int]
        /// A fixed moment, for fixed schedules.
        let fixed: Date?
        /// The next ring: the scheduled time, or the end of a snooze. Nil while ringing, or a snooze ReGlass didn't see
        /// start.
        let next: Date?

        var repeats: Bool { !days.isEmpty }
    }

    enum Blocked: Error {
        /// Never asked, and ReGlass isn't on screen to ask.
        case needsAppOpen
        /// Asked just now on screen; the owner hasn't answered yet.
        case askedOnScreen
        case denied
        /// ReGlass's records can't be read yet (the iPhone hasn't been unlocked since it restarted).
        case locked
    }

    enum ScheduleProblem: Error {
        case blocked(Blocked)
        case tooMany
        /// AlarmKit's own limit (`maximumLimitReached`).
        case systemLimit
        case failed
    }

    /// ReGlass keeps at most this many alarms.
    nonisolated static let maxAlarms = 20
    static let snooze: TimeInterval = TimeInterval(ReGlassAlarmLook.snoozeMinutes * 60)
    /// A record younger than this is kept even if AlarmKit's list doesn't show it yet.
    private static let newRecordGrace: TimeInterval = 20

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var authorization: AlarmManager.AuthorizationState

    private var records: [Record] = []
    private var recordsReadable = true
    private var kitAlarms: [Alarm] = []
    /// When each snoozed alarm rings again, as far as ReGlass saw the snooze start.
    private var snoozeEnds: [UUID: Date] = [:]
    private var updatesTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var authorizationRequest: Task<AlarmManager.AuthorizationState, Never>?
    private var observers: [NSObjectProtocol] = []

    private var manager: AlarmManager { AlarmManager.shared }

    private init() {
        // Nothing here may reach ConnectorRegistry or GlassesController: this runs inside the registry's set-up.
        authorization = AlarmManager.shared.authorizationState
        loadRecords()
        Task { @MainActor [weak self] in self?.started() }
    }

    private func started() {
        readAlarms()
        if !kitAlarms.isEmpty { log("Alarms: \(kitAlarms.count) set") }
        let updates = manager.alarmUpdates
        updatesTask = Task { [weak self] in
            for await alarms in updates { self?.apply(alarms) }
        }
        let authorizations = manager.authorizationUpdates
        authorizationTask = Task { [weak self] in
            for await state in authorizations { self?.authorizationChanged(state) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.recordsReadable else { return }
                self.loadRecords()
                self.readAlarms()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Switched on or off in iPhone Settings meanwhile.
                self.authorizationChanged(AlarmManager.shared.authorizationState)
                self.readAlarms()
            }
        })
    }

    // MARK: Permission

    /// Asks iOS once (ReGlass must be on screen). Concurrent callers share one prompt.
    @discardableResult
    func requestAuthorization() async -> AlarmManager.AuthorizationState {
        if let pending = authorizationRequest { return await pending.value }
        let request = Task { @MainActor () -> AlarmManager.AuthorizationState in
            do {
                return try await AlarmManager.shared.requestAuthorization()
            } catch {
                return AlarmManager.shared.authorizationState
            }
        }
        authorizationRequest = request
        let state = await request.value
        authorizationRequest = nil
        authorizationChanged(state)
        log("Alarms: access \(state == .authorized ? "allowed" : "not allowed")")
        return state
    }

    /// Nil when alarms can be set now. Not asked yet with ReGlass on screen: shows iOS's prompt and waits up to
    /// `wait` for the answer.
    func checkAllowed(wait: TimeInterval) async -> Blocked? {
        if !recordsReadable { loadRecords() }
        guard recordsReadable else { return .locked }
        switch manager.authorizationState {
        case .authorized:
            return nil
        case .denied:
            return .denied
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else { return .needsAppOpen }
            Task { await self.requestAuthorization() }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline, !Task.isCancelled, manager.authorizationState == .notDetermined {
                try? await Task.sleep(for: .milliseconds(200))
            }
            switch manager.authorizationState {
            case .authorized: return nil
            case .denied: return .denied
            default: return .askedOnScreen
            }
        @unknown default:
            return .denied
        }
    }

    /// iOS's answer right now (the published `authorization` can lag a change made in iPhone Settings).
    func liveAuthorization() -> AlarmManager.AuthorizationState {
        let state = manager.authorizationState
        if state != authorization { authorizationChanged(state) }
        return state
    }

    private func authorizationChanged(_ state: AlarmManager.AuthorizationState) {
        guard state != authorization else { return }
        authorization = state
        ConnectorRegistry.shared.refresh()
        readAlarms()
    }

    // MARK: Setting, snoozing, stopping, cancelling

    func schedule(_ resolved: AlarmClock.Resolved, label: String?) async -> Result<Record, ScheduleProblem> {
        if let blocked = await checkAllowed(wait: 6) { return .failure(.blocked(blocked)) }
        readAlarms()
        guard kitAlarms.count < Self.maxAlarms else { return .failure(.tooMany) }

        let schedule: Alarm.Schedule
        let kind: Record.Kind
        var time: AlarmClock.ClockTime?
        var days: [Int] = []
        switch resolved.plan {
        case .next(let t, _):
            schedule = .relative(.init(time: .init(hour: t.hour, minute: t.minute), repeats: .never))
            kind = .next
            time = t
        case .weekly(let t, let weekly, _):
            schedule = .relative(.init(time: .init(hour: t.hour, minute: t.minute),
                                       repeats: .weekly(weekly.compactMap(Self.weekday))))
            kind = .weekly
            time = t
            days = weekly
        case .fixed(let date):
            schedule = .fixed(date)
            kind = .fixed
        }

        let id = UUID()
        let record = Record(id: id, label: label, kind: kind, time: time, days: days, fire: resolved.plan.fire, created: Date())
        // Noted first, so an `alarmUpdates` list that arrives during scheduling can't drop it (see newRecordGrace).
        records.append(record)
        do {
            _ = try await manager.schedule(id: id, configuration: Self.configuration(schedule: schedule, label: label))
        } catch {
            records.removeAll { $0.id == id }
            if case AlarmManager.AlarmError.maximumLimitReached = error {
                log("Alarms: iOS's alarm limit reached (\(kitAlarms.count) set)")
                return .failure(.systemLimit)
            }
            log("Alarms: couldn't set an alarm (\(type(of: error)))")
            return .failure(.failed)
        }
        saveRecords()
        readAlarms()
        log("Alarms: set (\(kind.rawValue), \(kitAlarms.count) set)")
        return .success(record)
    }

    /// Cancels for good (a repeating alarm stops repeating).
    func cancel(_ ids: [UUID]) -> [UUID] {
        var done: [UUID] = []
        for id in ids {
            do {
                try manager.cancel(id: id)
                done.append(id)
            } catch {
                // Already gone counts as cancelled; AlarmKit's next list settles it.
                if !kitAlarms.contains(where: { $0.id == id }) { done.append(id) }
            }
        }
        if !done.isEmpty {
            records.removeAll { done.contains($0.id) }
            done.forEach { snoozeEnds[$0] = nil }
            saveRecords()
            log("Alarms: cancelled \(done.count)")
        }
        readAlarms()
        return done
    }

    /// Snoozes a ringing alarm for nine minutes. Returns when it rings again.
    func snooze(_ id: UUID) -> Date? {
        do {
            try manager.countdown(id: id)
        } catch {
            log("Alarms: couldn't snooze (\(type(of: error)))")
            return nil
        }
        let end = Date().addingTimeInterval(Self.snooze)
        snoozeEnds[id] = end
        log("Alarms: snoozed")
        readAlarms()
        return end
    }

    /// Stops a ringing or snoozed alarm: a one-off is done, a repeating one waits for its next day.
    func stop(_ id: UUID) -> Bool {
        do {
            try manager.stop(id: id)
        } catch {
            log("Alarms: couldn't stop (\(type(of: error)))")
            return false
        }
        snoozeEnds[id] = nil
        log("Alarms: stopped")
        readAlarms()
        return true
    }

    // MARK: Reading

    /// Every alarm, ringing first, then soonest first. Recomputed for `now`.
    func currentEntries(now: Date = Date(), timeZone: TimeZone = .current) -> [Entry] {
        readAlarms()
        return makeEntries(now: now, timeZone: timeZone)
    }

    private func readAlarms() {
        guard manager.authorizationState == .authorized else {
            // Can't see them; keep ReGlass's notes for when access comes back.
            if !kitAlarms.isEmpty || !entries.isEmpty { apply([], prune: false) }
            return
        }
        do {
            apply(try manager.alarms)
        } catch {
            log("Alarms: couldn't read the alarms (\(type(of: error)))")
        }
    }

    private func apply(_ alarms: [Alarm], prune: Bool = true) {
        // ReGlass only makes alarms with a schedule; anything else isn't its own to show. Reminders' countdowns
        // (Connectors/ReGlassReminders/) are alarms to AlarmKit too, but not the owner's alarms.
        let reminders = ReminderScheduler.shared.reminderAlarmIDs
        kitAlarms = alarms.filter { $0.schedule != nil && !reminders.contains($0.id) }
        let now = Date()
        for alarm in kitAlarms {
            switch alarm.state {
            case .countdown:
                // Snoozed from the Lock Screen while ReGlass watched: it rings again a snooze from now.
                if snoozeEnds[alarm.id] == nil { snoozeEnds[alarm.id] = now.addingTimeInterval(Self.snooze) }
            default:
                snoozeEnds[alarm.id] = nil
            }
        }
        let live = Set(kitAlarms.map(\.id))
        snoozeEnds = snoozeEnds.filter { live.contains($0.key) }
        if prune, recordsReadable {
            let kept = records.filter { live.contains($0.id) || now.timeIntervalSince($0.created) < Self.newRecordGrace }
            if kept.count != records.count {
                let gone = records.count - kept.count
                records = kept
                saveRecords()
                log("Alarms: \(gone) done or cancelled outside ReGlass")
            }
        }
        let fresh = makeEntries(now: now, timeZone: .current)
        if fresh != entries { entries = fresh }
    }

    private func makeEntries(now: Date, timeZone: TimeZone) -> [Entry] {
        let clock = AlarmClock(now: now, timeZone: timeZone)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let list = kitAlarms.compactMap { alarm -> Entry? in
            guard let schedule = alarm.schedule else { return nil }
            let record = byID[alarm.id]
            var time: AlarmClock.ClockTime?
            var days: [Int] = []
            var fixed: Date?
            var next: Date?
            switch schedule {
            case .fixed(let date):
                fixed = date
                next = date
            case .relative(let relative):
                let t = AlarmClock.ClockTime(hour: relative.time.hour, minute: relative.time.minute)
                time = t
                switch relative.repeats {
                case .weekly(let weekdays):
                    days = weekdays.compactMap(Self.dayNumber).sorted()
                    next = clock.nextWeekly(t, days: Set(days))
                default:
                    // The day it was set for while that's still ahead; after a time zone change, the next round.
                    if let record, record.fire > now, record.time == t { next = record.fire } else { next = clock.next(t) }
                }
            @unknown default:
                return nil
            }
            let state: Entry.State
            switch alarm.state {
            case .alerting:
                state = .ringing
                next = nil
            case .countdown:
                state = .snoozed
                next = snoozeEnds[alarm.id]
            case .paused:
                state = .paused
                next = nil
            default:
                state = .set
            }
            return Entry(id: alarm.id, label: record?.label, state: state, time: time, days: days, fixed: fixed, next: next)
        }
        return list.sorted { a, b in
            if (a.state == .ringing) != (b.state == .ringing) { return a.state == .ringing }
            return (a.next ?? .distantFuture) < (b.next ?? .distantFuture)
        }
    }

    // MARK: AlarmKit set-up

    private static func configuration(schedule: Alarm.Schedule, label: String?) -> AlarmManager.AlarmConfiguration<ReGlassAlarmMetadata> {
        let title = label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Alarm"
        let snoozeButton = AlarmButton(text: "Snooze", textColor: ReGlassAlarmLook.accent, systemImageName: "zzz")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: resource(title), secondaryButton: snoozeButton, secondaryButtonBehavior: .countdown)
        } else {
            alert = AlarmPresentation.Alert(title: resource(title),
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
                                            secondaryButton: snoozeButton, secondaryButtonBehavior: .countdown)
        }
        // The snooze countdown's look when the Live Activity can't show (before the first unlock after a restart).
        let countdown = AlarmPresentation.Countdown(title: resource(label == nil ? "Snoozed" : "\(title), snoozed"))
        let attributes = AlarmAttributes<ReGlassAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert, countdown: countdown),
            metadata: ReGlassAlarmMetadata(label: label),
            tintColor: ReGlassAlarmLook.accentFill)
        return AlarmManager.AlarmConfiguration<ReGlassAlarmMetadata>(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze),
            schedule: schedule,
            attributes: attributes)
    }

    private static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }

    private static let weekdayOrder: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ number: Int) -> Locale.Weekday? {
        weekdayOrder.indices.contains(number - 1) ? weekdayOrder[number - 1] : nil
    }

    static func dayNumber(_ weekday: Locale.Weekday) -> Int? {
        weekdayOrder.firstIndex(of: weekday).map { $0 + 1 }
    }

    // MARK: Storage

    /// Application Support/ReGlass/Alarms/alarms.json, readable after the first unlock (labels are content).
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ReGlass/Alarms/alarms.json", directoryHint: .notDirectory)
    }

    private func loadRecords() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            records = []
            recordsReadable = true
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            // Protected until the first unlock: never overwrite it meanwhile.
            recordsReadable = false
            return
        }
        records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        recordsReadable = true
    }

    private func saveRecords() {
        guard recordsReadable else { return }
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log("Alarms: couldn't save ReGlass's alarm notes (\(type(of: error)))")
        }
    }

    private func log(_ line: String) {
        GlassesController.shared.log.add(line)
    }
}
