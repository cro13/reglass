import Foundation

/// A speech recognizer the owner can choose for what they say to ReGlass (Settings → Assistant → Voice and speech),
/// and the one list of them (`all`).
///
/// **Adding a recognizer** (docs/VOICE.md shows the shape):
/// 1. A type conforming to `RecognitionEngine` in ReGlassAssistant/Speech/. The contract (audio format, results,
///    the end of a request, cancellation, errors) is on the protocol, in Transcriber.swift.
/// 2. Its provider beside it: `extension SpeechProvider { static let openAI = SpeechProvider(...) }`.
/// 3. One line in `all`.
///
/// Whatever is chosen, Apple's recognizer on the iPhone stands by: a request the chosen one can't take (no key, a key
/// problem, a recent failure) goes to the iPhone's, and an engine that fails part-way can hand its request over.
/// A provider that needs an API key names it in `key`; a new key is a new `AssistantKey` case (see `VoiceProvider`).
public struct SpeechProvider: Sendable, Identifiable, Hashable {
    /// Saved as the owner's choice: never change it once a provider has shipped.
    public let id: String
    /// The row's name ("iPhone (on-device)").
    public let title: String
    /// A few words under the name.
    public let subtitle: String
    /// One plain sentence on where the wearer's voice goes.
    public let privacy: String
    /// The API key it needs, if any.
    public let key: AssistantKey?
    /// For the log ("iPhone", "ElevenLabs").
    public let logName: String
    /// Makes one request's engine, or nil when it can't take this request: the iPhone's recognizer listens then.
    /// Called as each request starts, while the wearer is already speaking: return at once and connect in the
    /// background (audio appended meanwhile must be kept, not lost).
    let makeEngine: @Sendable (_ request: RecognitionRequest) async -> RecognitionEngine?

    /// What's missing before it can listen, as one plain sentence; nil when nothing is.
    public var missing: String? {
        if let key, !KeyStore.shared.has(key) { return "Needs your \(key.providerName) key." }
        return nil
    }

    public static func == (a: SpeechProvider, b: SpeechProvider) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What one request's engine is made for.
struct RecognitionRequest: Sendable {
    /// Where the engine's results go: `update(_:isFinal:)`, `engineStopped(_:)`, `languageDetected(_:)`.
    let owner: Transcriber
    /// The language to listen for (ISO 639-1). The live interpreter passes the language it interprets.
    let language: String?
    /// Makes Apple's recognizer on the iPhone, for an engine that fails part-way and hands the request over.
    let standIn: @Sendable () async -> RecognitionEngine?
}

public extension SpeechProvider {
    /// Every recognizer the owner can choose, in the order the settings screen lists them. The first is the default.
    static let all: [SpeechProvider] = [
        .iPhone,
        .elevenLabs,
    ]

    static func with(id: String) -> SpeechProvider? { all.first { $0.id == id } }

    /// Apple's recognizer on this iPhone: SpeechTranscriber, or the older on-device SFSpeechRecognizer.
    static let iPhone = SpeechProvider(
        id: "iPhone", title: "iPhone (on-device)", subtitle: "Apple's recognizer, on this iPhone",
        privacy: "What you say is written down on this iPhone. The audio doesn't leave it.",
        key: nil, logName: "iPhone", makeEngine: { request in await request.standIn() })

    /// ElevenLabs Scribe v2 Realtime (`ScribeEngine`), with the ElevenLabs key.
    static let elevenLabs = SpeechProvider(
        id: "elevenLabs", title: "ElevenLabs Scribe", subtitle: "In the cloud, better with accents and names",
        privacy: "What you say goes to ElevenLabs to be written down, with the names of towns near you.",
        key: .elevenLabs, logName: "ElevenLabs",
        makeEngine: { request in
            ScribeEngine.make(owner: request.owner, language: request.language, standIn: request.standIn)
        })
}
