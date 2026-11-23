import EventKit
import ReGlassAssistant
import SwiftUI
import UIKit

/// Apple Calendar: what's on, free time, and adding events after a spoken yes. Reads every calendar on the iPhone,
/// including the Google Workspace calendar synced into it. Works with the iPhone locked once it has been unlocked
/// since a restart.
@MainActor
final class CalendarConnector: Connector {
    static let connectorID = "calendar"

    let id = CalendarConnector.connectorID
    let name = "Calendar"
    let symbol = "calendar"
    let summary = "Your iPhone's calendars, Google ones included. ReGlass tells you what's on, finds free time and adds events once you say yes."
    let examples = [
        "What's on my calendar today?",
        "Am I free tomorrow afternoon?",
        "Add lunch with Alex on Thursday at one",
    ]
    let group = ConnectorGroup.iPhone
    let tools: [any AssistantTool]

    private let store = CalStore()

    init() {
        tools = [ListEventsTool(store: store), FindFreeTimeTool(store: store), AddEventTool(store: store)]
    }

    func status() -> ConnectorStatus {
        switch CalStore.access {
        case .fullAccess:
            return .ready
        case .notDetermined:
            return .needsSetup(message: "Allow ReGlass to see your calendar.", action: "Allow Access")
        case .writeOnly:
            return .needsSetup(message: "ReGlass can add events but can't read your calendar yet.", action: "Allow Full Access")
        case .denied:
            return .needsSetup(message: "Calendar access is off for ReGlass. Turn it on in iPhone Settings.",
                               action: "Open iPhone Settings")
        case .restricted:
            return .unavailable("Calendar access isn't allowed on this iPhone.")
        @unknown default:
            return .unavailable("Calendar isn't available on this iPhone.")
        }
    }

    func setUp() async {
        let before = CalStore.access
        switch before {
        case .notDetermined, .writeOnly:
            let granted = await store.requestAccess()
            GlassesController.shared.log.add("Calendar: access \(granted ? "allowed" : "not allowed")")
            // iOS asks only once; after that, the switch lives in the Settings app.
            if !granted && before == .writeOnly { await openSettings() }
        case .denied, .restricted:
            await openSettings()
        default:
            break
        }
        ConnectorRegistry.shared.refresh()
    }

    func settingsView() -> AnyView? {
        AnyView(CalendarSettingsView(store: store))
    }

    private func openSettings() async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        _ = await UIApplication.shared.open(url)
    }
}
