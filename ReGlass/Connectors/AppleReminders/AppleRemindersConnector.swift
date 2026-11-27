import EventKit
import ReGlassAssistant
import SwiftUI
import UIKit

/// Apple Reminders: adds, reads and ticks off reminders in the iPhone's Reminders app, so they sync through iCloud to
/// the owner's other Apple devices. Off by default: ReGlass's own reminders and lists (Connectors/ReGlassReminders/,
/// Connectors/Lists/) stay the usual home, and this connector is for owners who live in Apple Reminders.
///
/// Works with the iPhone locked once it has been unlocked since a restart (`ReminderStore`).
@MainActor
final class AppleRemindersConnector: Connector {
    let id = "apple_reminders"
    let name = "Apple Reminders"
    let symbol = "list.bullet.rectangle"
    let summary = "The Reminders app on your iPhone, synced through iCloud. While it's on, ReGlass keeps your reminders, to-dos and lists there instead of in ReGlass."
    let examples = [
        "Add call the bank to my Reminders",
        "What's on my Groceries list in Reminders?",
        "Mark pick up dry cleaning as done in Reminders",
    ]
    let group = ConnectorGroup.iPhone
    let onByDefault = false
    let tools: [any AssistantTool]

    private let store = ReminderStore(log: { line in
        Task { @MainActor in GlassesController.shared.log.add(line) }
    })

    init() {
        tools = [AddAppleRemindersTool(store: store), ListAppleRemindersTool(store: store),
                 CompleteAppleReminderTool(store: store), GetAppleReminderListsTool(store: store)]
    }

    func status() -> ConnectorStatus {
        switch ReminderStore.access {
        case .allowed:
            return .ready
        case .notAsked:
            return .needsSetup(message: "Allow ReGlass to use your Reminders.", action: "Allow Access")
        case .denied:
            return .needsSetup(message: "Reminders access is off for ReGlass. Turn it on in iPhone Settings.",
                               action: "Open iPhone Settings")
        }
    }

    func setUp() async {
        switch ReminderStore.access {
        case .notAsked:
            let granted = await store.requestAccess()
            GlassesController.shared.log.add("Apple Reminders: access \(granted ? "allowed" : "not allowed")")
        case .denied:
            // iOS asks only once; after that, the switch lives in the Settings app.
            if let url = URL(string: UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
        case .allowed:
            break
        }
        ConnectorRegistry.shared.refresh()
    }
}
