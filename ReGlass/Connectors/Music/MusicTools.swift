import Foundation
import ReGlassAssistant

// Claude's tools for Apple Music. Each one checks Claude's input, then hands a plain request to `MusicService`.
// The definitions are fixed text, so they stay in the cached prompt prefix.

// MARK: play_music

struct PlayMusicTool: AssistantTool {
    let service: MusicService

    var definition: ToolDefinition { Self.spec }

    static let spec = ToolDefinition(
        name: "play_music",
        description: """
        Play music in the Apple Music app on the owner's iPhone. It plays on their glasses and keeps playing after \
        you answer. Use it whenever the owner asks to play or put on music: an artist ("play some Rihanna"), a \
        song, an album ("play the new Taylor Swift album"), a playlist ("play my Discover playlist"), a station or \
        radio ("Rihanna radio"), a mood or genre ("something calm", "jazz"), or their own library ("shuffle my \
        library"). The music starts right away, before your answer. Kinds: artist plays the artist's top songs, \
        shuffled; station plays endless radio; playlist checks the owner's own playlists and Apple Music's mixes \
        for them first (use it for moods and genres too); album with newest true plays the artist's latest album; \
        library plays only the owner's own music (all of it with an empty query). Not for pausing, skipping, going \
        back, shuffle or repeat on what's already playing (use music_control), not for "what's playing?" (use \
        now_playing), and not for other music apps. Returns what is playing now (title and artist), what was picked and what \
        comes next, or why nothing plays. Confirm in one short sentence, for example "Playing Diamonds by Rihanna, \
        then more of her songs." Say "shuffled" when it is. If what was picked differs from what was asked, say \
        what it is. Never read IDs. If it failed, say why in a few words.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What to play, cleaned up: an artist, a song (add the artist if said: \"Diamonds Rihanna\"), an album, a playlist name, a station, a mood or genre. Leave out filler like \"some\", \"my\", \"playlist\", \"the new\". Empty string for the whole library.",
                ],
                "kind": [
                    "type": "string",
                    "enum": ["any", "song", "artist", "album", "playlist", "station", "library"],
                    "description": "What the owner asked for. Use any when it's unclear.",
                ],
                "shuffle": [
                    "type": "boolean",
                    "description": "true when the owner says shuffle, false when they say in order. Leave it out otherwise.",
                ],
                "newest": [
                    "type": "boolean",
                    "description": "true for the artist's new or latest album: \"the new Taylor Swift album\" is query \"Taylor Swift\", kind album, newest true.",
                ],
            ],
            "required": ["query"],
        ]
    )

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let (request, problem) = MusicRequest.parse(input)
        guard let request else {
            return .failure(problem ?? "The request couldn't be read.", action: ToolAction(title: "Couldn't play music"))
        }
        return await service.play(request)
    }
}

// MARK: music_control

struct MusicControlTool: AssistantTool {
    let service: MusicService

    var definition: ToolDefinition { Self.spec }

    static let spec = ToolDefinition(
        name: "music_control",
        description: """
        Control what the Apple Music app is playing on the owner's iPhone: pause, resume, next song, previous \
        song, start the song over, shuffle on or off, repeat this song, repeat all, repeat off. Use it for \
        "pause", "stop the music", "resume", "play again", "skip", "next song", "go back", "previous song", \
        "start this song over", "shuffle this", "repeat this song". It only controls Apple Music: if another app \
        is playing, it says so, and you tell the owner the glasses' touchpad does it instead (tap \
        to pause or play, double-tap to skip, triple-tap to go back). Not for playing something new (use \
        play_music). Returns the new state, and the song now playing after a skip. Answer in one or two words for \
        pause, resume, shuffle and repeat ("Paused."); after a skip, name the new song briefly.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": .array(MusicService.ControlAction.allCases.map { .string($0.rawValue) }),
                    "description": "What to do. previous goes to the song before; restart starts the current song over.",
                ],
            ],
            "required": ["action"],
        ]
    )

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let raw = (input["action"]?.string ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        let aliases: [String: MusicService.ControlAction] = [
            "stop": .pause, "play": .resume, "skip": .next, "back": .previous, "shuffle": .shuffleOn,
            "repeat": .repeatOne, "unshuffle": .shuffleOff, "no_repeat": .repeatOff,
        ]
        guard let action = MusicService.ControlAction(rawValue: raw) ?? aliases[raw] else {
            return .failure("Unknown action. Use one of: "
                            + MusicService.ControlAction.allCases.map(\.rawValue).joined(separator: ", ") + ".",
                            action: ToolAction(title: "Couldn't control music"))
        }
        return await service.control(action)
    }
}

// MARK: now_playing

struct NowPlayingMusicTool: AssistantTool {
    let service: MusicService

    var definition: ToolDefinition { Self.spec }

    static let spec = ToolDefinition(
        name: "now_playing",
        description: """
        Tell what the Apple Music app on the owner's iPhone is playing: title, artist, album, and whether it's \
        playing or paused. Use it for "what's playing?", "what song is this?", "who sings this?", "what album is \
        this from?". If Apple Music isn't playing but another app is, it says so; ReGlass can't see \
        that app's song, so say that plainly. Music often shows as paused while you are speaking; if it says \
        paused, just name the song. Returns short facts. Answer in one sentence, title then artist.
        """,
        inputSchema: [
            "type": "object",
            "properties": [:],
        ]
    )

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        await service.nowPlaying()
    }
}
