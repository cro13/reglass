import ReGlassAssistant
import SwiftUI

/// Timers that ring on the glasses, and the voice saying what each was for when it ends. Works without the glasses too:
/// the iPhone keeps every timer and says it there (see `TimerService`).
@MainActor
final class TimersConnector: Connector {
    let id = "timers"
    let name = "Timers"
    let symbol = "timer"
    let summary = "Timers that ring on your glasses. When one ends, ReGlass tells you what it was for."
    let examples = [
        "Make me a timer to check on my food in one minute",
        "How long's left on the pasta?",
        "Cancel the laundry timer",
    ]
    let group: ConnectorGroup = .glasses

    private let service = TimerService.shared

    func status() -> ConnectorStatus { .ready }

    func setUp() async {}

    var tools: [any AssistantTool] {
        [SetTimerTool(service: service), ListTimersTool(service: service), CancelTimerTool(service: service)]
    }
}
