import AlarmKit
import ReGlassAssistant
import SwiftUI
import UIKit

/// Real iPhone alarms by voice, through AlarmKit: "wake me at seven", "six forty-five on weekdays". They ring through
/// Silent mode and Focus, show on the Lock Screen, and need ReGlass neither open nor running. Countdown timers stay with
/// the Timers connector (they ring on the glasses).
@MainActor
final class AlarmsConnector: Connector {
    static let connectorID = "alarms"

    let id = AlarmsConnector.connectorID
    let name = "Alarms"
    let symbol = "alarm"
    let summary = "Alarms on your iPhone, set by voice. They ring even when ReGlass is closed, with a nine-minute snooze."
    let examples = [
        "Wake me at seven",
        "Set an alarm for six forty-five on weekdays",
        "What alarms do I have?",
    ]
    let group = ConnectorGroup.iPhone
    let tools: [any AssistantTool]

    private let service = AlarmService.shared

    init() {
        tools = [
            SetAlarmTool(service: service),
            ListAlarmsTool(service: service),
            CancelAlarmTool(service: service),
            SnoozeAlarmTool(service: service),
        ]
    }

    func status() -> ConnectorStatus {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return .ready
        case .notDetermined:
            return .needsSetup(message: "Allow ReGlass to set alarms on this iPhone.", action: "Allow Alarms")
        case .denied:
            return .needsSetup(message: "Alarms are off for ReGlass. Turn them on in iPhone Settings.",
                               action: "Open iPhone Settings")
        @unknown default:
            return .unavailable("Alarms aren't available on this iPhone.")
        }
    }

    func setUp() async {
        switch AlarmManager.shared.authorizationState {
        case .notDetermined:
            await service.requestAuthorization()
        case .denied:
            // iOS asks only once; after a "Don't Allow" the switch lives in the Settings app.
            if let url = URL(string: UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
        default:
            break
        }
        ConnectorRegistry.shared.refresh()
    }

    func settingsView() -> AnyView? {
        AnyView(AlarmsSettingsView(service: service))
    }
}
