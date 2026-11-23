import AlarmKit
import ReGlassAssistant
import SwiftUI
import UIKit

/// ReGlass's own reminders, by voice: "remind me in six minutes to check on the food". They live in ReGlass's library
/// (the Reminders screen), and go off once, in the most direct place: the voice says them on
/// the glasses while they're worn, otherwise the iPhone alerts (`ReminderScheduler`). Apple Reminders lists stay with
/// the Lists connector.
@MainActor
final class ReGlassRemindersConnector: Connector {
    let id = "reglass-reminders"
    let name = "Reminders"
    let symbol = "bell"
    let summary = "Reminders by voice. ReGlass says each one on your glasses when it's due, or your iPhone alerts you when you're not wearing them."
    let examples = [
        "Remind me in six minutes to check on the food",
        "Remind me tomorrow at nine to call the dentist",
        "Move the food reminder to eight",
        "What reminders do I have?",
    ]
    let group = ConnectorGroup.glasses
    let tools: [any AssistantTool] = [SetReminderTool(), ListReGlassRemindersTool(), ChangeReminderTool(),
                                      CancelReminderTool(), SnoozeReminderTool()]

    private let scheduler = ReminderScheduler.shared

    init() {
        // Delivery runs whether or not this connector is switched on: reminders typed on the Reminders screen go off
        // too.
        scheduler.start()
    }

    func status() -> ConnectorStatus {
        switch scheduler.notificationPermission {
        case .allowed:
            return .ready
        case .notAsked:
            return .needsSetup(message: "Allow notifications, so your iPhone can alert you when you're not wearing your glasses.",
                               action: "Allow Notifications")
        case .denied:
            return .needsSetup(message: "Notifications are off for ReGlass. Turn them on in iPhone Settings so your iPhone can alert you.",
                               action: "Open iPhone Settings")
        }
    }

    func setUp() async {
        if scheduler.notificationPermission == .denied {
            // iOS asks only once; after a "Don't Allow" the switch lives in the Settings app.
            if let url = URL(string: UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
            return
        }
        await scheduler.requestNotificationPermission()
        // Reminders due within the hour count down on the Lock Screen through AlarmKit (Alarms' permission).
        if AlarmManager.shared.authorizationState == .notDetermined {
            await AlarmService.shared.requestAuthorization()
        }
        ConnectorRegistry.shared.refresh()
    }
}
