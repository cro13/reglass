import Foundation
import ReGlassAssistant
import SwiftUI

/// The live interpreter, as a connector (experimental, off until the owner switches it on): Claude's
/// `start_interpreter` tool, and ReGlass's own match for "interpreter, French". Switched off in Settings →
/// Connectors, the interpreter can't start by voice; its screen (Settings → Assistant → Live interpreter) still works.
/// Nothing else in the assistant changes while it isn't running.
@MainActor
final class InterpreterConnector: Connector {
    nonisolated static let connectorID = "interpreter"

    let id = InterpreterConnector.connectorID
    let name = "Interpreter"
    let symbol = "character.bubble"
    let summary = "ReGlass tells you in English what someone says in another language, through your glasses. "
        + "Your own English isn't translated."
    let examples = [
        "Interpreter, French",
        "Start interpreting Spanish",
        "Stop interpreting",
    ]
    let group: ConnectorGroup = .glasses
    let isExperimental = true
    let onByDefault = false

    /// Unavailable without what it can't work without ("Needs an ElevenLabs key."). Starting it checks the rest
    /// (`InterpreterSession.blocker()`).
    func status() -> ConnectorStatus {
        if let missing = InterpreterSession.missingSetup() { return .unavailable(missing) }
        return .ready
    }

    func setUp() async {}

    var tools: [any AssistantTool] { [StartInterpreterTool()] }

    /// The Real time switch.
    func settingsView() -> AnyView? { AnyView(InterpreterSettingsView()) }
}

struct StartInterpreterTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "start_interpreter",
            description: """
            Starts ReGlass's live interpreter on the user's glasses. From the moment your reply ends, ReGlass listens \
            to the other person and tells the user in English what they said. It works one way only: the user's own \
            English is recognised and not translated, so nothing is said to the other person in their language. It \
            keeps going without the wake word until the user says "stop interpreting". Use it when the user asks for \
            an interpreter, to interpret or translate what someone is saying, or for help understanding someone who \
            speaks another language: "interpreter, French", "start interpreting Spanish", "help me understand this \
            man, he speaks Italian". Not for translating one phrase or word ("how do you say thank you in German"): \
            answer that yourself. If the user didn't say which language, ask before calling. Returns whether it \
            started. When it started, your whole reply must be one short sentence such as "Interpreting French. Go \
            ahead.", with no tips or questions, because ReGlass starts listening right after it. When it didn't \
            start, say why in one sentence.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "language": [
                        "type": "string",
                        "description": """
                        The other person's language, named in English: "French", "German", "Spanish", "Romanian". \
                        Translations are always into English.
                        """,
                    ],
                ],
                "required": ["language"],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let asked = input["language"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !asked.isEmpty else {
            return .failure("No language was given. Ask the user which language the other person speaks.")
        }
        guard context.surface == .glasses else {
            return .failure("The interpreter runs on the glasses. The user can say \"Hey Meta, interpreter, \(asked)\" "
                            + "with the glasses on.")
        }
        guard let language = InterpreterLanguage.named(asked) else {
            let offered = InterpreterLanguage.common.map(\.name).joined(separator: ", ")
            return .failure("ReGlass's interpreter can't do \(asked) yet. It can do \(offered) and about twenty-five "
                            + "more, such as Greek, Hungarian, Turkish, Japanese and Chinese.",
                            action: ToolAction(title: "Couldn't start the interpreter", detail: "\(asked) isn't offered yet"))
        }
        guard language != .english else {
            return .failure("The interpreter translates another language into English. Ask which language the other "
                            + "person speaks.")
        }
        let blocker: String? = await MainActor.run { InterpreterSession.blocker() }
        if let blocker {
            return .failure(blocker, action: ToolAction(title: "Couldn't start the interpreter", detail: blocker))
        }
        await MainActor.run { InterpreterSession.shared.requestFromVoice(language) }
        let result: JSONValue = [
            "started": true,
            "translates": .string("\(language.name) into English"),
            "note": "ReGlass starts listening as soon as your reply ends. Reply with one short sentence only.",
        ]
        let text = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"started\":true}"
        return .success(text, action: ToolAction(title: "Started the interpreter", detail: "\(language.name) to English"))
    }
}
