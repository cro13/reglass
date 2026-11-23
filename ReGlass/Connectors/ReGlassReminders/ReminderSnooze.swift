import Foundation

/// Snoozing a reminder: by voice, from the ringing alert, the notification or the reminder's
/// row. Every route ends in `LibraryStore.snoozeReminder`, so the scheduler places its alerts afresh.
@MainActor
enum ReminderSnooze {
    /// How long the context note mentions a reminder that went off ("Hey Meta, snooze" within half an hour).
    static let mentionFor: TimeInterval = 30 * 60
    /// How long after going off a reminder is still the one `snooze_reminder` takes when none is named.
    static let snoozableFor: TimeInterval = 60 * 60

    /// "A reminder went off 3 minutes ago: check on the food." for the context note while one went off (or was
    /// snoozed) within the last 30 minutes, so "Hey Meta, snooze" knows which; nil otherwise.
    static func contextLine(now: Date = .now) -> String? {
        guard let last = latest(within: mentionFor, now: now) else { return nil }
        let minutes = Int(now.timeIntervalSince(last.at) / 60)
        let ago = minutes < 1 ? "just now" : (minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago")
        guard last.snoozed else { return "A reminder went off \(ago): \(last.reminder.title)." }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        return "A reminder was snoozed \(ago): \(last.reminder.title). It goes off again at \(time.string(from: last.reminder.due))."
    }

    /// The reminder a bare "snooze" means: the one that went off or was snoozed most recently within `window`.
    /// `snoozed`: it's the one snoozed last and still waiting to ring again, so a new snooze counts from now.
    static func latest(within window: TimeInterval,
                       now: Date = .now) -> (reminder: ReminderSnapshot, at: Date, snoozed: Bool)? {
        let fired = wentOff(within: window, now: now).first
        let snoozed = waitingAfterSnooze(within: window, now: now)
        if let snoozed, fired.map({ snoozed.at >= $0.at }) ?? true { return (snoozed.reminder, snoozed.at, true) }
        return fired.map { ($0.reminder, $0.at, false) }
    }

    /// The reminder snoozed last, when that was within `window` and it's still waiting to ring again (open, not on
    /// its way out).
    static func waitingAfterSnooze(within window: TimeInterval,
                                   now: Date = .now) -> (reminder: ReminderSnapshot, at: Date)? {
        guard let last = LibraryStore.shared.lastSnooze, now.timeIntervalSince(last.at) < window,
              let reminder = LibraryStore.shared.reminder(last.id), reminder.isOpen,
              !ReminderScheduler.isLeaving(reminder.id) else { return nil }
        return (reminder, last.at)
    }

    /// Reminders that went off within `window` and haven't been ticked off or moved since (a move opens one again),
    /// the latest first, each with when it went off. One whose time has passed that ReGlass hasn't marked yet (iOS had it
    /// suspended) counts from its due time. None on its way out (deleted on screen, its Undo still showing).
    static func wentOff(within window: TimeInterval, now: Date = .now) -> [(reminder: ReminderSnapshot, at: Date)] {
        let store = LibraryStore.shared
        let marked = store.earlierReminders(limit: 20).compactMap { reminder -> (reminder: ReminderSnapshot, at: Date)? in
            guard reminder.completed == nil, let fired = reminder.fired else { return nil }
            return (reminder, fired)
        }
        let unmarked = store.upcomingReminders().filter { $0.due <= now }.map { (reminder: $0, at: $0.due) }
        return (marked + unmarked)
            .filter { now.timeIntervalSince($0.at) < window && !ReminderScheduler.isLeaving($0.reminder.id) }
            .sorted { $0.at > $1.at }
    }
}
