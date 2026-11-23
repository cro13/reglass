import ReGlassAssistant
import SwiftUI

/// Notes by voice: "take a note: a bike rack that folds into the wall". ReGlass keeps the owner's words (fillers dropped,
/// never summarised) in its own library, apart from Chats, where the Notes screen shows them; the voice
/// reads them back on request. Nothing to allow: it's ReGlass's own store.
///
/// Also offers `move_to_category` ("that's not shopping, it's for the office") for notes, reminders and list items
/// alike, and Recently Deleted's `list_recently_deleted` and `put_back` for those and chats: Notes is the connector
/// that's always been on with nothing to set up (see Connectors/Lists/CategoryTools.swift, RecentlyDeletedTools.swift).
@MainActor
final class NotesConnector: Connector {
    let id = "notes"
    let name = "Notes"
    let symbol = "note.text"
    let summary = "Say an idea and it's saved, word for word, in ReGlass. Ask for your notes back any time."
    let examples = [
        "Take a note: a bike rack that folds into the wall",
        "Note that the office wifi password is on the fridge",
        "What were my notes about the bike rack?",
    ]
    let group = ConnectorGroup.glasses
    let tools: [any AssistantTool] = [TakeNoteTool(), FindNotesTool(), AddToNoteTool(), MoveToCategoryTool(),
                                      ListRecentlyDeletedTool(), PutBackTool()]

    func status() -> ConnectorStatus { .ready }

    func setUp() async {}
}
