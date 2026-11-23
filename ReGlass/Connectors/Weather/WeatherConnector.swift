import ReGlassAssistant
import SwiftUI

/// Weather by voice: a real forecast for where the owner is (or any town), instead of a web search that guessed the
/// city from the time zone. "Here" comes from the iPhone's location: a fresh fix with Always, else the last known
/// position, else the home city set in the options.
@MainActor
final class WeatherConnector: Connector {
    let id = "weather"
    let name = "Weather"
    let symbol = "cloud.sun"
    let summary = "Forecasts for where you are or any town, up to a week ahead, so ReGlass can tell you when to take a jacket or an umbrella."
    let examples = [
        "What's the weather like?",
        "Will it rain this afternoon?",
        "What about tomorrow in Lyon?",
        "Do I need a jacket tonight?",
    ]
    let group = ConnectorGroup.places
    let tools: [any AssistantTool] = [GetWeatherTool()]

    func status() -> ConnectorStatus {
        let hasHome = HomeCityStore.shared.city != nil
        switch LocationService.shared.access {
        case .always, .whileUsing:
            return .ready
        case .notAsked:
            return .needsSetup(message: "Allow location so ReGlass knows where you are. Choose Always so it also works with your iPhone locked.",
                               action: "Allow Location")
        case .denied:
            return .needsSetup(message: hasHome
                               ? "Location is off for ReGlass, so it uses your home city. Turn it on in iPhone Settings, ideally Always."
                               : "Location is off for ReGlass. Turn it on in iPhone Settings, ideally Always, or set a home city below.",
                               action: "Open iPhone Settings")
        case .restricted:
            return .needsSetup(message: hasHome
                               ? "Location isn't allowed on this iPhone, so ReGlass uses your home city."
                               : "Location isn't allowed on this iPhone. Set a home city below so ReGlass knows where you are.",
                               action: "Open iPhone Settings")
        }
    }

    func setUp() async {
        await LocationService.shared.setUp()
        ConnectorRegistry.shared.refresh()
    }

    func settingsView() -> AnyView? {
        AnyView(WeatherSettingsView())
    }
}
