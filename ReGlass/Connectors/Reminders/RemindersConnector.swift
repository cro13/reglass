import ReGlassAssistant
import SwiftUI

/// Lists: things to do or buy with no time, by voice ("I need to buy milk, coffee and Coke"), kept in ReGlass's own
/// library as tick-off items, one checklist per category, in the Reminders tab. The voice says which list each went
/// on. Nothing to allow: it's ReGlass's own store (Connectors/Lists/).
///
/// Apple Reminders stays as it is (nothing is imported); `ReminderStore` is kept for a later link of one category to
/// an Apple Reminders list. "Remind me …" is ReGlass's own Reminders connector (Connectors/ReGlassReminders/). The id
/// is "reminders".
@MainActor
final class RemindersConnector: Connector {
    let id = "reminders"
    let name = "Lists"
    let symbol = "checklist"
    let summary = "Say what you need to buy or do, and ReGlass puts it on the right list, like Shopping or To-do. Tick things off by voice or in Reminders."
    let examples = [
        "I need to buy milk, coffee and Coke",
        "What's on my shopping list?",
        "I bought the milk",
        "Clear the shopping list",
    ]
    let group = ConnectorGroup.glasses
    let tools: [any AssistantTool] = [AddToListTool(), ReadListTool(), TickOffListItemTool(), GetListsTool()]

    func status() -> ConnectorStatus { .ready }

    func setUp() async {}

    func settingsView() -> AnyView? {
        AnyView(RemindersSettingsView())
    }
}
