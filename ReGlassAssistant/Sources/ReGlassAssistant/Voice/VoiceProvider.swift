import Foundation

/// A voice the owner can choose for ReGlass's replies (Settings → Assistant → Voice and speech), and the one list of
/// them (`all`).
///
/// **Adding a voice** (docs/VOICE.md has a worked example):
/// 1. A type conforming to `Voice` in ReGlassAssistant/Voice/. The contract (audio format, streaming, cancellation,
///    errors) is on the protocol.
/// 2. Its provider beside it: `extension VoiceProvider { static let openAI = VoiceProvider(...) }`.
/// 3. One line in `all`.
///
/// The settings screen then lists it, with its privacy line, its Test, and its key's row in place while the key is
/// missing. A provider that needs an API key names it in `key`; a new key is a new `AssistantKey` case, plus its words
/// and section on the Keys screen and its Test in `AssistantController.testKey` (the compiler points at each). Settings
/// of its own (ElevenLabs' voice ID) need a row in the app.
public struct VoiceProvider: Sendable, Identifiable, Hashable {
    /// Saved as the owner's choice: never change it once a provider has shipped.
    public let id: String
    /// The row's name ("iPhone (on-device)").
    public let title: String
    /// A few words under the name.
    public let subtitle: String
    /// One plain sentence on where the reply's text goes.
    public let privacy: String
    /// The API key it needs, if any.
    public let key: AssistantKey?
    /// For the log ("Apple", "ElevenLabs").
    public let logName: String
    /// What it still needs before it can speak, as one plain sentence; nil when it's ready. Answers at once (no network).
    private let needs: @Sendable () -> String?
    /// Makes the voice, once (`ChosenVoice` keeps it). `fallback` is Apple's voice on the iPhone: hand it whatever is
    /// left of a reply when this voice can't speak, so the wearer still hears an answer.
    let make: @Sendable (_ fallback: any Voice) -> any Voice
    /// A Test of its own, when the voice can say more than the generic one (`trial`) about what went wrong.
    private let test: (@Sendable (_ line: String) async -> VoiceTrial)?

    init(id: String, title: String, subtitle: String, privacy: String, key: AssistantKey?, logName: String,
         needs: @escaping @Sendable () -> String? = { nil },
         test: (@Sendable (_ line: String) async -> VoiceTrial)? = nil,
         make: @escaping @Sendable (_ fallback: any Voice) -> any Voice) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.privacy = privacy
        self.key = key
        self.logName = logName
        self.needs = needs
        self.test = test
        self.make = make
    }

    /// What's missing before this voice can speak (its key first), or nil when nothing is.
    public var missing: String? {
        if let key, !KeyStore.shared.has(key) { return "Needs your \(key.providerName) key." }
        return needs()
    }

    /// The settings screen's Test: `line` in this voice, with its audio to play, or one plain sentence on why not.
    /// Without a test of its own, the voice says it with Apple's voice standing by, and a hand-over to Apple's voice
    /// counts as a failure, with the reason the voice gave.
    public func trial(_ line: String) async -> VoiceTrial {
        if let test { return await test(line) }
        let voice = make(AppleVoice())
        let route = RouteRecorder()
        do {
            var samples: [Int16] = []
            for try await chunk in voice.speak(line, onRoute: { route.last = $0 }) { samples += chunk }
            if self != .iPhone, case .apple(let reason)? = route.last {
                return .failed(reason ?? "\(title) didn't speak, so Apple's voice did.")
            }
            guard !samples.isEmpty else { return .failed("The voice made no sound.") }
            return .works(samples: samples, message: "Works.")
        } catch {
            if !(error is CancellationError) { AssistantLog.add("Voice test: \(logName) failed (\(type(of: error)))") }
            return .failed("\(title) couldn't speak. Check its key, then try again.")
        }
    }

    public static func == (a: VoiceProvider, b: VoiceProvider) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public extension VoiceProvider {
    /// Every voice the owner can choose, in the order the settings screen lists them. The first is the default.
    static let all: [VoiceProvider] = [
        .iPhone,
        .elevenLabs,
    ]

    static func with(id: String) -> VoiceProvider? { all.first { $0.id == id } }

    /// Apple's voice, made on the iPhone: the default, and every other voice's fallback.
    static let iPhone = VoiceProvider(
        id: "iPhone", title: "iPhone (on-device)", subtitle: "Apple's voice, made on this iPhone",
        privacy: "Replies are spoken on this iPhone. Their text doesn't leave it.",
        key: nil, logName: "Apple", make: { fallback in fallback })

    /// A voice from the owner's ElevenLabs account (`ElevenLabsVoice`), with its key and voice ID.
    static let elevenLabs = VoiceProvider(
        id: "elevenLabs", title: "ElevenLabs", subtitle: "A voice from your ElevenLabs account",
        privacy: "Each reply's text goes to ElevenLabs to be spoken.",
        key: .elevenLabs, logName: "ElevenLabs",
        needs: { VoiceSettings.elevenLabsVoiceID.isEmpty ? "Needs a voice ID." : nil },
        test: { line in await ElevenLabsVoice(fallback: nil).trial(line) },
        make: { fallback in ElevenLabsVoice(fallback: fallback) })
}

/// What the settings screen's Test heard.
public enum VoiceTrial: Sendable, Equatable {
    /// `samples`: the line, as 24 kHz mono PCM, to play. `message`: one plain sentence for the screen.
    case works(samples: [Int16], message: String)
    case failed(String)
}

/// The last route a voice reported.
private final class RouteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var route: VoiceRoute?

    var last: VoiceRoute? {
        get { lock.withLock { route } }
        set { lock.withLock { route = newValue } }
    }
}

/// The voice the owner chose, looked up as each reply starts, so a change applies from the next reply. Each
/// provider's voice is made the first time it's needed, then kept.
public final class ChosenVoice: Voice, @unchecked Sendable {
    public var name: String { VoiceSettings.provider.logName }
    private let fallback: any Voice
    private let lock = NSLock()
    private var made: [String: any Voice] = [:]

    /// `fallback`: the voice every provider hands over to, and the iPhone choice itself.
    public init(fallback: any Voice = AppleVoice()) {
        self.fallback = fallback
    }

    public func speak(_ sentences: AsyncStream<String>,
                      onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        voice(for: VoiceSettings.provider).speak(sentences, onRoute: onRoute)
    }

    /// `provider`'s voice, made now if it hasn't been.
    public func voice(for provider: VoiceProvider) -> any Voice {
        lock.withLock {
            if let voice = made[provider.id] { return voice }
            let voice = provider.make(fallback)
            made[provider.id] = voice
            return voice
        }
    }
}
