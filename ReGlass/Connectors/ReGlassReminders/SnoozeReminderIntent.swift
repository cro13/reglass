import AlarmKit
import AppIntents
import Foundation

/// The Snooze button on a ringing reminder's iPhone alert (`ReminderScheduler.countdown`: AlarmKit's secondary button,
/// custom behaviour). AlarmKit runs it in ReGlass's process, waking ReGlass if iOS had it stopped. The ringing stops at
/// once; the reminder moves `LibraryStore.snoozeMinutes` ahead and opens again, so the scheduler places its alert as for
/// a fresh reminder (the countdown, then the voice's line, or the glasses if they're on by then). It carries ids only,
/// never the words. App only: the widget extension draws no reminder buttons.
struct SnoozeReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze reminder"
    static let isDiscoverable = false

    @Parameter(title: "Reminder")
    var reminderID: String

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(reminder: UUID, alarm: UUID) {
        self.reminderID = reminder.uuidString
        self.alarmID = alarm.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Only a reminder the library can find can ring again. Before the first unlock after a restart the library
        // can't be read: it keeps ringing then (Stop still works) rather than going quiet for good.
        guard let reminder = UUID(uuidString: reminderID), LibraryStore.shared.reminder(reminder) != nil else {
            GlassesController.shared.log.add("Reminders: snooze from the alert couldn't read the library, so it keeps ringing")
            return .result()
        }
        // A custom button leaves the alarm itself to the app: stopped first, so the ringing ends whatever happens next.
        if let alarm = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: alarm) }
        await ReminderScheduler.shared.snoozeFromAlert(reminder, via: "alert")
        return .result()
    }
}
