import ActivityKit
import AlarmKit
import Combine
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Delivers ReGlass's own reminders (`ReGlassReminder` in `LibraryStore`): once each, in the most direct place.
///
/// It reconciles at launch, on every `LibraryStore.didChange` and whenever ReGlass comes to the foreground:
/// - every open reminder gets an iPhone alert of its own: an AlarmKit alarm, however far off. It stays out of sight
///   until `countdownLead` before it's due; then the Lock Screen, the Dynamic Island and the Watch count down
///   (ReGlassWidgets draws it, from `ReGlassAlarmMetadata.reminderTitle`) and the iPhone rings at the end. So "in two
///   weeks" never sits on the Lock Screen for two weeks. Without alarm permission: a time-sensitive local notification
///   at the due time; without either, no iPhone alert. Either alert sounds with the voice saying the reminder
///   (`ReminderVoice`, recorded as it's placed), or the system sound when it couldn't be recorded.
/// - ticked off or deleted: its alerts are removed (a running countdown ends, a ringing one stops, a delivered
///   notification goes). Moved to a new time: the old alert goes and a new one is placed.
/// - deleted on screen with its Undo still showing (`LibraryToast.hidden`): treated as gone already. Its alert is
///   removed at once and it doesn't go off, even if it comes due within those seconds; Undo places it again (one that
///   came due meanwhile goes off then, a few seconds late).
///
/// At the due time, while ReGlass runs (it does while the glasses are connected: the assistant's background audio):
/// - glasses connected and worn (or worn unknown): a moment before, ReGlass removes its own iPhone alert, and the voice
///   says the reminder on the glasses through the path timers use (`AssistantController.announce`; through the iPhone
///   if the glasses' assistant turns it down), so it's heard once;
/// - otherwise the iPhone alert goes off by itself; if there's none (no permission), the voice says it through the
///   iPhone's audio route only (never into glasses lying on a desk).
/// The wait for the due time ends in a short, precise sleep (`finalApproach`), so the hand-off beats the iPhone's alert.
/// Either way it's marked `fired`, once. One that came due while iOS had ReGlass suspended went off on the iPhone; it's
/// marked when ReGlass next runs, and also said on the glasses if they're on and it's fresh (`staleAfter`).
///
/// Snooze on the ringing alert (`SnoozeReminderIntent`) or the notification ("Snooze 10 min") moves the reminder
/// `LibraryStore.snoozeMinutes` ahead and opens it again (`snoozeFromAlert`), so it's placed afresh like a new one.
///
/// ReGlass keeps a small note per placed alert (reminder id, due time, kind, AlarmKit id; never the words) in a file
/// readable after the first unlock, so a relaunch doesn't place a second one. The activity log gets counts and states
/// only.
@MainActor
final class ReminderScheduler: NSObject, ObservableObject {
    static let shared = ReminderScheduler()

    /// Whether iOS lets ReGlass post notifications, as the screens and the connector show it.
    enum NotificationPermission: Equatable {
        case notAsked
        case allowed
        case denied
    }

    /// One iPhone alert ReGlass placed for a reminder.
    struct Placed: Codable, Equatable {
        enum Kind: String, Codable {
            /// An AlarmKit alarm, whose countdown shows only in its last `countdownLead`. (The stored name is from when
            /// only reminders due within the hour got one.)
            case countdown
            /// A local notification at the due time (no alarm permission, or placed before alarms took over).
            case notification
            /// None could be placed (no permission); ReGlass's own check says it through the iPhone.
            case noAlert
        }

        let reminder: UUID
        /// The due time it was placed for (a moved reminder gets a new one).
        let due: Date
        let kind: Kind
        /// The AlarmKit alarm, for a countdown.
        let alarm: UUID?
        /// The voice's line as the alert's sound (a file in Library/Sounds), when it could be recorded.
        var sound: String? = nil
    }

    /// Last known answer; refreshed at launch, in the foreground and before each reconcile.
    @Published private(set) var notificationPermission: NotificationPermission = .notAsked

    /// How long before a reminder is due its countdown appears on the Lock Screen. Due sooner when it's placed: the
    /// countdown starts at once.
    static let countdownLead: TimeInterval = 10 * 60
    /// A reminder that came due longer ago than this (ReGlass wasn't running) isn't announced (as `TimerService.staleAfter`).
    static let staleAfter: TimeInterval = 10 * 60
    /// How long before the due time ReGlass takes a reminder over from the iPhone's alert (and the assistant's voice starts).
    static let handOffLead: TimeInterval = 2
    /// The long wait for the next reminder ends this far ahead of the hand-off, and a short, precise one follows: iOS
    /// may wake a long sleep late (by up to a tenth of it, at most a minute), which would let the iPhone's alert ring
    /// before ReGlass takes it away.
    private static let finalApproach: TimeInterval = 30
    /// Due sooner than this: no iPhone alert of its own; ReGlass's own check is about to take it.
    static let minimumLead: TimeInterval = 3
    /// Notes about reminders that went off are kept this long (a later tick-off still clears their alert).
    static let keepFired: TimeInterval = 24 * 3600
    private static let notificationPrefix = "reglass.reminder."

    private var placed: [UUID: Placed] = [:]
    private var placedReadable = true
    private var started = false
    private var ready = false
    private var reconciling = false
    private var reconcileAgain = false
    private var watch: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var leavingWatch: AnyCancellable?
    /// Reminders the voice is saying right now.
    private var announcing: Set<UUID> = []
    /// Every reminder seen open during this run. One of them that goes missing was deleted, even when the library
    /// fell back to memory (all it holds then was made this run).
    private var seenThisRun: Set<UUID> = []

    private override init() {
        super.init()
        start()
    }

    /// Starts reconciling (idempotent). The Reminders connector calls it when the registry makes it; touching
    /// `shared` does too.
    func start() {
        guard !started else { return }
        started = true
        // Before launch finishes (the app delegate starts it), so a notification's Snooze that woke ReGlass reaches it.
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.setNotificationCategories([Self.notificationCategory])
        // Nothing here may reach ConnectorRegistry, AssistantController or GlassesController: this can run inside
        // their own set-up.
        Task { @MainActor [weak self] in self?.begin() }
    }

    private func begin() {
        loadPlaced()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSoon() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSoon() }
        })
        observers.append(center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placedReadable else { return }
                self.loadPlaced()
                self.reconcileSoon()
            }
        })
        // A delete on screen, and its Undo. (Published before the change lands; the reconcile runs after it.)
        leavingWatch = LibraryToast.shared.$hidden.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSoon() }
        }
        ready = true
        let open = LibraryStore.shared.upcomingReminders().count
        if open > 0 { log("Reminders: \(open) coming up") }
        reconcileSoon()
    }

    // MARK: Permission (the screens and the connector)

    /// iOS's answer right now.
    @discardableResult
    func refreshNotificationPermission() async -> NotificationPermission {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let state: NotificationPermission
        switch status {
        case .authorized, .provisional, .ephemeral: state = .allowed
        case .denied: state = .denied
        case .notDetermined: state = .notAsked
        @unknown default: state = .denied
        }
        setPermission(state)
        return state
    }

    /// Asks iOS for notifications, once. Only with ReGlass on screen (the Reminders screen's first appearance, the
    /// connector's set-up button), never from a voice turn in the background: then it just returns the current state.
    @discardableResult
    func requestNotificationPermission() async -> NotificationPermission {
        let current = await refreshNotificationPermission()
        guard current == .notAsked, UIApplication.shared.applicationState == .active else { return current }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log("Reminders: asking for notifications failed (\(type(of: error)))")
        }
        let state = await refreshNotificationPermission()
        log("Reminders: notifications \(state == .allowed ? "allowed" : "not allowed")")
        return state
    }

    /// The iPhone can alert for a reminder due at `due` (an AlarmKit countdown or a notification is allowed).
    func phoneCanAlert(at due: Date) -> Bool {
        AlarmManager.shared.authorizationState == .authorized || notificationPermission == .allowed
    }

    private func setPermission(_ state: NotificationPermission) {
        guard state != notificationPermission else { return }
        let nowAllowed = state == .allowed
        notificationPermission = state
        ConnectorRegistry.shared.refresh()
        // Reminders that couldn't get an iPhone alert before get one now.
        if nowAllowed { reconcileSoon() }
    }

    // MARK: Reconciling

    /// Brings the iPhone's alerts in line with the library. Runs one at a time; a change meanwhile runs it again.
    func reconcileSoon() {
        guard ready else { return }
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.reconcileAgain = false
                await self.reconcile()
            } while self.reconcileAgain
            self.reconciling = false
            self.rewatch()
        }
    }

    private func reconcile() async {
        if !placedReadable { loadPlaced() }
        // Before the first unlock after a restart: wait for protectedDataDidBecomeAvailable.
        guard placedReadable else { return }
        await refreshNotificationPermission()
        let store = LibraryStore.shared
        // A library that fell back to memory (it couldn't open its store) doesn't know every reminder: then only one
        // seen during this run counts as deleted when it goes missing.
        let trusted = store.isStoredOnDisk
        let all = store.upcomingReminders()
        seenThisRun.formUnion(all.map(\.id))
        let open = all.filter { !Self.isLeaving($0.id) }
        let openByID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var changed = false
        var removed = 0

        for record in Array(placed.values) {
            if Self.isLeaving(record.reminder) {
                // Deleted on screen, its Undo still showing: no alert meanwhile.
                remove(record)
                removed += 1
                changed = true
                continue
            }
            if let reminder = openByID[record.reminder] {
                let moved = abs(reminder.due.timeIntervalSince(record.due)) > 1
                let upgradable = record.kind == .noAlert && reminder.due.timeIntervalSinceNow > Self.minimumLead
                    && phoneCanAlert(at: reminder.due)
                if moved || upgradable {
                    remove(record)
                    changed = true
                    if moved { removed += 1 }
                }
                continue
            }
            if let reminder = store.reminder(record.reminder) {
                if reminder.completed != nil {
                    // Ticked off: no alert, not even a ringing one.
                    remove(record)
                    removed += 1
                    changed = true
                } else if now.timeIntervalSince(record.due) > Self.keepFired {
                    // Went off a while ago: forget the note, leave whatever's left of the alert.
                    placed[record.reminder] = nil
                    changed = true
                }
            } else if trusted || seenThisRun.contains(record.reminder) {
                remove(record)
                removed += 1
                changed = true
            }
        }

        var countdowns = 0
        var notifications = 0
        var none = 0
        for reminder in open where placed[reminder.id] == nil && !announcing.contains(reminder.id) {
            guard reminder.due.timeIntervalSinceNow > Self.minimumLead else { continue }
            let record = await place(reminder)
            changed = true
            // It may have been ticked off, deleted, moved or taken by ReGlass's own check while that ran.
            guard let fresh = store.reminder(reminder.id), fresh.isOpen, fresh.due == reminder.due,
                  placed[reminder.id] == record, !announcing.contains(reminder.id), !Self.isLeaving(reminder.id) else {
                remove(record)
                continue
            }
            switch record.kind {
            case .countdown: countdowns += 1
            case .notification: notifications += 1
            case .noAlert: none += 1
            }
        }

        if changed { savePlaced() }
        // Sounds whose alerts are gone (ticked off, deleted, moved to a new line, taken over by the glasses).
        ReminderVoice.keepOnly(Set(placed.values.compactMap(\.sound)))
        if countdowns + notifications + none > 0 {
            var parts: [String] = []
            if countdowns > 0 { parts.append("\(countdowns) countdown\(countdowns == 1 ? "" : "s")") }
            if notifications > 0 { parts.append("\(notifications) notification\(notifications == 1 ? "" : "s")") }
            if none > 0 { parts.append("\(none) without an iPhone alert (\(notificationPermission == .denied ? "notifications off" : "not allowed yet"))") }
            log("Reminders: placed " + parts.joined(separator: ", "))
        }
        if removed > 0 { log("Reminders: removed \(removed) iPhone alert\(removed == 1 ? "" : "s")") }
    }

    /// Places the iPhone's alert for an open reminder. Each attempt is noted (and saved) before it's scheduled, so
    /// ReGlass being stopped meanwhile can't leave an alert it doesn't know about, which a relaunch would place again;
    /// an attempt that fails is replaced by the next.
    private func place(_ reminder: ReminderSnapshot) async -> Placed {
        let countdown = AlarmManager.shared.authorizationState == .authorized
        guard countdown || notificationPermission == .allowed else {
            return note(Placed(reminder: reminder.id, due: reminder.due, kind: .noAlert, alarm: nil))
        }
        // Recorded before anything is scheduled, so the time left is measured after it.
        let sound = await voice(for: reminder)
        if countdown {
            let record = note(Placed(reminder: reminder.id, due: reminder.due, kind: .countdown, alarm: UUID(),
                                     sound: sound))
            do {
                let alarm = record.alarm ?? UUID()
                _ = try await AlarmManager.shared.schedule(id: alarm,
                                                           configuration: Self.countdown(reminder, alarm: alarm, sound: sound))
                return record
            } catch {
                log("Reminders: couldn't schedule the alarm (\(type(of: error))); a notification instead")
            }
        }
        if notificationPermission == .allowed {
            let record = note(Placed(reminder: reminder.id, due: reminder.due, kind: .notification, alarm: nil,
                                     sound: sound))
            do {
                let wait = max(1, reminder.due.timeIntervalSinceNow)
                try await UNUserNotificationCenter.current().add(Self.notification(reminder, wait: wait, sound: sound))
                return record
            } catch {
                log("Reminders: couldn't schedule a notification (\(type(of: error)))")
            }
        }
        return note(Placed(reminder: reminder.id, due: reminder.due, kind: .noAlert, alarm: nil))
    }

    /// The voice's line as the alert's sound, when there's time to record it before the reminder is due.
    private func voice(for reminder: ReminderSnapshot) async -> String? {
        guard reminder.due.timeIntervalSinceNow > ReminderVoice.timeout + Self.minimumLead else { return nil }
        let line = ReminderSpeech.dueLine(title: reminder.title, announcement: reminder.announcement, lateBy: 0)
        return await ReminderVoice.sound(for: line, reminder: reminder.id)
    }

    /// Notes a placement and saves the notes straight away.
    private func note(_ record: Placed) -> Placed {
        placed[record.reminder] = record
        savePlaced()
        return record
    }

    /// Places an open reminder's iPhone alert again, after its title changed: the Lock Screen countdown and the
    /// notification show the title, and a note doesn't keep it to compare.
    func replaceAlert(for id: UUID) {
        guard let record = placed[id] else { return }
        remove(record)
        savePlaced()
        reconcileSoon()
    }

    /// Deleted on screen, with its Undo still showing: on its way out, so it neither goes off nor is offered to
    /// Claude.
    static func isLeaving(_ id: UUID) -> Bool {
        LibraryToast.shared.hidden.contains(id)
    }

    /// Takes away the alert a note describes (pending, running, ringing or delivered) and the note itself.
    private func remove(_ record: Placed) {
        if placed[record.reminder] == record { placed[record.reminder] = nil }
        switch record.kind {
        case .countdown:
            guard let alarm = record.alarm else { return }
            do {
                try AlarmManager.shared.cancel(id: alarm)
            } catch {
                // Already gone, or ringing right now.
                try? AlarmManager.shared.stop(id: alarm)
            }
        case .notification:
            let id = Self.notificationID(record.reminder)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        case .noAlert:
            break
        }
    }

    // MARK: The due time

    /// Sleeps until the next open reminder is about to come due.
    private func rewatch() {
        watch?.cancel()
        watch = nil
        guard let next = LibraryStore.shared.upcomingReminders().first(where: { !Self.isLeaving($0.id) }) else { return }
        let at = next.due.addingTimeInterval(-Self.handOffLead)
        watch = Task { @MainActor [weak self] in
            do {
                // Coarse, until shortly before, with a tolerance well inside the final approach.
                var wait = at.timeIntervalSinceNow - Self.finalApproach
                while wait > 0 {
                    try await Task.sleep(for: .seconds(wait), tolerance: .seconds(min(10, max(1, wait / 20))))
                    wait = at.timeIntervalSinceNow - Self.finalApproach
                }
                // Precise, for the last stretch.
                let rest = at.timeIntervalSinceNow
                if rest > 0 { try await Task.sleep(for: .seconds(rest), tolerance: .milliseconds(50)) }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.checkDue()
        }
    }

    private func checkDue() {
        guard placedReadable else { return }
        let now = Date()
        // A quarter second's slack: the sleep's clock and the wall clock can disagree slightly.
        for reminder in LibraryStore.shared.upcomingReminders()
        where reminder.due.addingTimeInterval(-Self.handOffLead - 0.25) <= now && !Self.isLeaving(reminder.id) {
            deliver(reminder, now: now)
        }
        rewatch()
    }

    private func deliver(_ reminder: ReminderSnapshot, now: Date) {
        guard !announcing.contains(reminder.id) else { return }
        let late = now.timeIntervalSince(reminder.due)
        let record = placed[reminder.id]
        let phoneAlert = record != nil && record?.kind != Placed.Kind.noAlert
        let live = GlassesController.shared.live
        let onGlasses = live.connection.isConnected && live.worn != false

        // Marked first, so a reconcile running meanwhile places nothing for it.
        LibraryStore.shared.markFired(reminder.id, at: late > 0 && !phoneAlert ? now : reminder.due)
        guard late < Self.staleAfter else {
            log("Reminders: one came due \(Int(late / 60)) min ago while ReGlass wasn't running; not announced")
            return
        }
        if onGlasses {
            // The voice says it on the glasses, so the iPhone doesn't too (a ringing countdown stops).
            if let record {
                remove(record)
                savePlaced()
            }
            announce(reminder, late: late, glasses: true)
        } else if !phoneAlert {
            // No iPhone alert could be placed: the voice says it through the iPhone, never into glasses that are known
            // to be off.
            announce(reminder, late: late, glasses: false)
        } else if late < 5 {
            log("Reminders: one went off on the iPhone (glasses \(live.connection.isConnected ? "not worn" : "not connected"))")
        } else {
            log("Reminders: one went off on the iPhone while ReGlass wasn't running")
        }
    }

    /// `glasses`: false keeps it off the glasses' player (they aren't being worn); the iPhone's audio route only.
    private func announce(_ reminder: ReminderSnapshot, late: TimeInterval, glasses: Bool) {
        announcing.insert(reminder.id)
        let line = ReminderSpeech.dueLine(title: reminder.title, announcement: reminder.announcement,
                                          lateBy: max(0, late))
        Task { @MainActor [weak self] in
            let route = await AssistantController.shared.announce(line, phoneFallback: true, glasses: glasses)
            guard let self else { return }
            self.announcing.remove(reminder.id)
            // Moved to a new time while it was being said: it gets its new iPhone alert now.
            self.reconcileSoon()
            self.log("Reminders: one came due; announcement: \(route)")
            // Neither the glasses nor the iPhone could say it: a notification now, if allowed.
            if route == .failed { await self.notifyNow(reminder) }
        }
    }

    private func notifyNow(_ reminder: ReminderSnapshot) async {
        guard notificationPermission == .allowed else { return }
        let content = Self.content(reminder)
        let request = UNNotificationRequest(identifier: Self.notificationID(reminder.id), content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log("Reminders: couldn't post a notification (\(type(of: error)))")
        }
    }

    // MARK: Alerts

    /// The AlarmKit alarm (`alarm` is its id): the Live Activity shows the reminder's title and the time left; the
    /// iPhone rings at the end, with the voice's line when there's one, and offers Snooze beside Stop. Snooze runs
    /// `SnoozeReminderIntent` in ReGlass (a custom button, not AlarmKit's own countdown), which moves the reminder in the
    /// library, so the Reminders tab and the next ring both follow. Due within `countdownLead`, it counts down
    /// from now. Later, it waits unseen: its schedule starts the countdown (AlarmKit rings `preAlert` after the
    /// schedule's date, not at it), so the countdown appears `countdownLead` before the due time and ends on it.
    private static func countdown(_ reminder: ReminderSnapshot, alarm: UUID,
                                  sound: String?) -> AlarmManager.AlarmConfiguration<ReGlassAlarmMetadata> {
        let title = ReminderSpeech.displayTitle(reminder.title)
        let snooze = AlarmButton(text: "Snooze", textColor: ReGlassAlarmLook.accent, systemImageName: "zzz")
        let alert = AlarmPresentation.Alert(title: resource(title), secondaryButton: snooze,
                                            secondaryButtonBehavior: .custom)
        let snoozeIntent = SnoozeReminderIntent(reminder: reminder.id, alarm: alarm)
        // Shown where the Live Activity can't be (before the first unlock after a restart).
        let countdown = AlarmPresentation.Countdown(title: resource("Reminder: \(title)"))
        let attributes = AlarmAttributes<ReGlassAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert, countdown: countdown),
            metadata: ReGlassAlarmMetadata(reminderTitle: title),
            tintColor: ReGlassAlarmLook.accentFill)
        let tone: AlertConfiguration.AlertSound = sound.map { .named($0) } ?? .default
        let wait = reminder.due.timeIntervalSinceNow
        guard wait > countdownLead else {
            return .timer(duration: max(1, wait), attributes: attributes, secondaryIntent: snoozeIntent, sound: tone)
        }
        return AlarmManager.AlarmConfiguration<ReGlassAlarmMetadata>(
            countdownDuration: Alarm.CountdownDuration(preAlert: countdownLead, postAlert: nil),
            schedule: .fixed(reminder.due.addingTimeInterval(-countdownLead)),
            attributes: attributes,
            secondaryIntent: snoozeIntent,
            sound: tone)
    }

    private static func notification(_ reminder: ReminderSnapshot, wait: TimeInterval, sound: String?) -> UNNotificationRequest {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        let content = content(reminder)
        if let sound { content.sound = UNNotificationSound(named: UNNotificationSoundName(sound)) }
        return UNNotificationRequest(identifier: notificationID(reminder.id), content: content, trigger: trigger)
    }

    private static func content(_ reminder: ReminderSnapshot) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = ReminderSpeech.displayTitle(reminder.title)
        content.sound = .default
        // Breaks through a Focus that allows time-sensitive alerts (needs the Time Sensitive capability; without it
        // iOS delivers it as a normal alert).
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "reglass.reminders"
        // Offers "Snooze 10 min" (`notificationCategory`).
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["reminder": reminder.id.uuidString]
        return content
    }

    private static func notificationID(_ reminder: UUID) -> String {
        notificationPrefix + reminder.uuidString
    }

    private static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(text))
    }

    private func log(_ line: String) {
        GlassesController.shared.log.add(line)
    }

    // MARK: Storage

    /// Application Support/ReGlass/Reminders/alerts.json, readable after the first unlock.
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ReGlass/Reminders/alerts.json", directoryHint: .notDirectory)
    }

    private func loadPlaced() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            placed = [:]
            placedReadable = true
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            // Protected until the first unlock: never overwrite it meanwhile.
            placedReadable = false
            return
        }
        let list = (try? JSONDecoder().decode([Placed].self, from: data)) ?? []
        placed = Dictionary(list.map { ($0.reminder, $0) }, uniquingKeysWith: { _, last in last })
        placedReadable = true
    }

    private func savePlaced() {
        guard placedReadable else { return }
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(placed.values)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log("Reminders: couldn't save ReGlass's alert notes (\(type(of: error)))")
        }
    }
}

// MARK: Notifications while ReGlass is on screen

extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// iOS hides an app's own notifications while it's in the foreground unless asked: show reminders as usual. (One
    /// handed to the glasses was removed before it was due, so it never gets here.)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// The notification's "Snooze 10 min" (iOS wakes ReGlass in the background for it). A plain tap just opens ReGlass.
    /// The interpreter's "keep interpreting" goes on with the iPhone's microphone.
    ///
    /// The completion-handler form, called back on the main thread once the work is done. The `async` form returned
    /// to iOS from a background thread, and UIKit aborts the app when that happens with it in the background (a
    /// notification's buttons crashed it that way).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let requestID = response.notification.request.identifier
        let action = response.actionIdentifier
        let reminder = (response.notification.request.content.userInfo["reminder"] as? String)
            .flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            await self.handleResponse(action, to: requestID, reminder: reminder)
            completionHandler()
        }
    }

    private func handleResponse(_ action: String, to requestID: String, reminder: UUID?) async {
        if InterpreterSession.handlesNotification(requestID) {
            await InterpreterSession.shared.continueOnIPhone()
            return
        }
        guard action == Self.snoozeActionID, let reminder else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
        await snoozeFromAlert(reminder, via: "notification")
    }
}

// MARK: Snooze from the iPhone's alert

extension ReminderScheduler {
    nonisolated static let categoryID = "reglass.reminder"
    nonisolated static let snoozeActionID = "reglass.reminder.snooze"
    /// How long a snooze from the alert waits for the new alert to be placed (the voice's line takes up to
    /// `ReminderVoice.timeout` to record).
    private static let snoozeSettle: TimeInterval = 15

    /// A reminder notification's actions: "Snooze 10 Min" (as on the reminder's row in ReGlass), in the background (no unlock, ReGlass stays closed).
    static var notificationCategory: UNNotificationCategory {
        let snooze = UNNotificationAction(identifier: snoozeActionID, title: "Snooze \(LibraryStore.snoozeMinutes) Min",
                                          options: [], icon: UNNotificationActionIcon(systemImageName: "zzz"))
        return UNNotificationCategory(identifier: categoryID, actions: [snooze], intentIdentifiers: [], options: [])
    }

    /// Snoozes a reminder from its iPhone alert: the ringing alert's Snooze (`SnoozeReminderIntent`, which has stopped
    /// the ringing) or the notification's action. It moves `LibraryStore.snoozeMinutes` ahead and opens again, so the
    /// reconcile takes its old alert away and places a new one as for a fresh reminder (the countdown, the voice's line).
    /// iOS may suspend ReGlass as soon as the button's work returns, so this waits until that's done, for at most
    /// `snoozeSettle`. `via` is for the log ("alert", "notification").
    @discardableResult
    func snoozeFromAlert(_ id: UUID, via: String) async -> ReminderSnapshot? {
        // A launch for the button itself: the store and the reconcile start here.
        start()
        guard !Self.isLeaving(id), let snoozed = LibraryStore.shared.snoozeReminder(id) else {
            log("Reminders: snooze from the \(via) found no reminder")
            return nil
        }
        log("Reminders: snoozed from the \(via) (\(LibraryStore.snoozeMinutes) min)")
        let deadline = Date().addingTimeInterval(Self.snoozeSettle)
        while Date() < deadline {
            let settled = ready && !reconciling
                && (!placedReadable || placed[id].map { abs($0.due.timeIntervalSince(snoozed.due)) <= 1 } ?? false)
            if settled { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return snoozed
    }

    /// An alarm is ringing right now that isn't one of the reminders' own countdowns, as far as ReGlass can tell:
    /// `snooze_reminder` with no title leaves "snooze" to `snooze_alarm` then.
    func alarmRinging() -> Bool {
        guard placedReadable, AlarmManager.shared.authorizationState == .authorized,
              let alarms = try? AlarmManager.shared.alarms else { return false }
        let reminders = reminderAlarmIDs
        return alarms.contains { $0.state == .alerting && !reminders.contains($0.id) }
    }

    /// The AlarmKit alarms that are reminders' countdowns, so the Alarms connector doesn't list them as the owner's
    /// alarms. Empty while ReGlass can't read its records (before the first unlock after a restart).
    var reminderAlarmIDs: Set<UUID> {
        Set(placed.values.compactMap(\.alarm))
    }
}

extension LibraryStore {
    /// False when the library fell back to memory for this launch (its store couldn't open): a reminder missing from
    /// it may still exist on disk.
    var isStoredOnDisk: Bool {
        container.configurations.contains { !$0.isStoredInMemoryOnly }
    }
}
