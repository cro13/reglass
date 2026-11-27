import Foundation
import ReGlassAssistant
import SwiftUI
import UIKit

/// Every connector, its on/off switch (remembered on this iPhone) and its status. Also the assistant's
/// `ToolProvider`: each request gets the tools of the connectors that are on and usable.
@MainActor
final class ConnectorRegistry: ObservableObject {
    static let shared = ConnectorRegistry()

    let connectors: [any Connector]
    @Published private(set) var statuses: [String: ConnectorStatus] = [:]
    /// Switches the owner changed; connectors not listed use `onByDefault`.
    @Published private var switches: [String: Bool]

    private static let switchesKey = "reglass.connectors.switches"
    private var observer: NSObjectProtocol?

    private init() {
        connectors = Self.makeConnectors()
        switches = UserDefaults.standard.dictionary(forKey: Self.switchesKey) as? [String: Bool] ?? [:]
        Self.checkToolNames(connectors)
        refresh()
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Every connector, in display order within its group. Each connector adds exactly one line here.
    private static func makeConnectors() -> [any Connector] {
        var all: [any Connector] = []
        all.append(TimersConnector())
        all.append(ReGlassRemindersConnector())
        all.append(NotesConnector())
        all.append(RemindersConnector())
        all.append(CalendarConnector())
        all.append(AppleRemindersConnector())
        all.append(AlarmsConnector())
        all.append(MusicConnector())
        all.append(WeatherConnector())
        all.append(InterpreterConnector())
        return all
    }

    // MARK: Switches and status

    func isOn(_ connector: any Connector) -> Bool {
        switches[connector.id] ?? connector.onByDefault
    }

    func setOn(_ on: Bool, for connector: any Connector) {
        switches[connector.id] = on
        UserDefaults.standard.set(switches, forKey: Self.switchesKey)
        GlassesController.shared.log.add("Connectors: \(connector.id) \(on ? "on" : "off")")
    }

    func status(of connector: any Connector) -> ConnectorStatus {
        statuses[connector.id] ?? connector.status()
    }

    /// Re-reads every connector's status.
    func refresh() {
        var fresh: [String: ConnectorStatus] = [:]
        for connector in connectors { fresh[connector.id] = connector.status() }
        if fresh != statuses { statuses = fresh }
    }

    func connector(id: String) -> (any Connector)? {
        connectors.first { $0.id == id }
    }

    /// The tools of every connector that's on and usable, plus the glasses' own audio settings tool.
    func activeTools() -> [any AssistantTool] {
        var tools = connectors.filter { isOn($0) && status(of: $0).isUsable }.flatMap { $0.tools }
        if GlassesController.shared.paired != nil {
            tools.append(GlassesAudioTool())
        }
        return tools
    }

    private static func checkToolNames(_ connectors: [any Connector]) {
        var seen: Set<String> = []
        for connector in connectors {
            for tool in connector.tools where !seen.insert(tool.definition.name).inserted {
                assertionFailure("Two connectors offer a tool named \(tool.definition.name)")
            }
        }
    }
}

extension ConnectorRegistry: ToolProvider {
    nonisolated func currentTools() async -> [any AssistantTool] {
        await MainActor.run { self.activeTools() }
    }
}

/// Switches Adaptive Volume (svc31 tag 80) and Spatial Audio (tag 286) on the glasses by voice.
struct GlassesAudioTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "set_glasses_audio",
            description: "Turns the glasses' own Adaptive Volume (automatic volume control for ambient noise) or Spatial Audio (head-tracked stereo) on or off when the owner asks ('turn on adaptive volume', 'turn off spatial audio').",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "adaptive_volume": .object([
                        "type": .string("boolean"),
                        "description": .string("True to turn Adaptive Volume on, false to turn it off.")
                    ]),
                    "spatial_audio": .object([
                        "type": .string("boolean"),
                        "description": .string("True to turn Spatial Audio on, false to turn it off.")
                    ])
                ])
            ])
        )
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let avc = input["adaptive_volume"]?.bool
        let spatial = input["spatial_audio"]?.bool
        guard avc != nil || spatial != nil else {
            return .failure("Pass adaptive_volume, spatial_audio, or both.")
        }
        return await MainActor.run {
            let glasses = GlassesController.shared
            var spoken: [String] = []
            if let avc {
                glasses.adaptiveVolume = avc
                spoken.append("Adaptive volume is \(avc ? "on" : "off").")
            }
            if let spatial {
                glasses.spatialAudio = spatial
                spoken.append("Spatial audio is \(spatial ? "on" : "off").")
            }
            let reply = spoken.joined(separator: " ")
            return .success(reply, action: ToolAction(title: "Glasses sound", detail: reply), spokenReply: reply)
        }
    }
}
