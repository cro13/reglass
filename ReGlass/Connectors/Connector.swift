import ReGlassAssistant
import SwiftUI

// A connector is one thing the assistant can reach: timers on the glasses, Reminders, Calendar, Apple Music,
// weather. Each one lives in its own folder under ReGlass/Connectors/<Name>/, registers itself with one line in
// `ConnectorRegistry.makeConnectors()`, and gives Claude its tools while it's switched on in Settings → Connectors.

/// Where a connector's row sits in Settings → Connectors.
enum ConnectorGroup: Int, CaseIterable, Comparable {
    case glasses
    case iPhone
    case places

    var title: String {
        switch self {
        case .glasses: return "On your glasses"
        case .iPhone: return "On your iPhone"
        case .places: return "Out and about"
        }
    }

    static func < (lhs: ConnectorGroup, rhs: ConnectorGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether a connector can work right now.
enum ConnectorStatus: Equatable {
    /// Working. Its tools go to Claude while it's switched on.
    case ready
    /// Needs the owner to allow something first (an iOS permission, a one-time choice). `message` says what, in one
    /// short sentence; `action` is the button title ("Allow access"). The tools still go to Claude, so a request
    /// meanwhile gets a spoken "allow access in ReGlass first" instead of "I can't do that".
    case needsSetup(message: String, action: String)
    /// Can't work right now for a reason that can't be fixed from its row ("Connect your glasses first"). Its tools
    /// are left out.
    case unavailable(String)

    var isUsable: Bool {
        switch self {
        case .ready, .needsSetup: return true
        case .unavailable: return false
        }
    }
}

@MainActor
protocol Connector: AnyObject {
    /// Stable, lowercase, used to remember the on/off switch: "timers", "reminders".
    var id: String { get }
    /// "Timers"
    var name: String { get }
    /// An SF Symbol: "timer".
    var symbol: String { get }
    /// One sentence on what it does, in the owner's terms: "Timers that ring on your glasses. The voice tells you
    /// what they were for."
    var summary: String { get }
    /// Two or three things to say: "Set a timer for ten minutes to check the oven".
    var examples: [String] { get }
    var group: ConnectorGroup { get }
    /// Shows a small "Experimental" mark.
    var isExperimental: Bool { get }
    /// Switched on for a new install, before the owner touches it.
    var onByDefault: Bool { get }

    /// The current status. Cheap (permission checks only); called when Settings opens and when ReGlass comes to the
    /// foreground. Call `ConnectorRegistry.shared.refresh()` after anything that changes it.
    func status() -> ConnectorStatus
    /// The owner tapped the setup button: ask iOS for access, etc. Runs in the foreground.
    func setUp() async
    /// Claude's tools while this connector is on and usable.
    var tools: [any AssistantTool] { get }
    /// Optional extra settings shown when the owner opens the connector (a default list, a home address, ...).
    func settingsView() -> AnyView?
}

extension Connector {
    var isExperimental: Bool { false }
    var onByDefault: Bool { true }
    func settingsView() -> AnyView? { nil }
}
