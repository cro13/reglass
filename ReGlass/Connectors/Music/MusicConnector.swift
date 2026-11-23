import ReGlassAssistant
import SwiftUI

/// Apple Music by voice: "play some Rihanna", "play my Discover playlist", "skip", "what's playing?". Music plays in
/// the Music app (the system player), so it keeps going after ReGlass is suspended, shows on the Lock Screen as Music,
/// and the glasses' touchpad keeps controlling it. ReGlass never becomes the Now Playing app.
@MainActor
final class MusicConnector: Connector {
    let id = "music"
    let name = "Apple Music"
    let symbol = "music.note"
    let summary = "Plays Apple Music on your glasses: an artist, an album, a playlist or your whole library. Skips, pauses and tells you what's on."
    let examples = [
        "Play some Rihanna",
        "Play my Discover playlist",
        "What's playing?",
    ]
    let group = ConnectorGroup.iPhone
    let tools: [any AssistantTool]

    private let service: MusicService

    init() {
        let service = MusicService.shared
        self.service = service
        tools = [
            PlayMusicTool(service: service),
            MusicControlTool(service: service),
            NowPlayingMusicTool(service: service),
        ]
    }

    func status() -> ConnectorStatus {
        service.connectorStatus()
    }

    func setUp() async {
        await service.setUp()
        ConnectorRegistry.shared.refresh()
    }

    /// The catalog-or-library state and its one-time hint, once access is allowed (before that, the connector
    /// screen's own "Allow access" button is the only step).
    func settingsView() -> AnyView? {
        guard service.isAuthorized else { return nil }
        return AnyView(MusicSettingsView(service: service))
    }
}
