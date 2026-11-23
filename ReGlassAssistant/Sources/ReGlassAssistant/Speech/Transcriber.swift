@preconcurrency import AVFoundation
import Foundation
import Speech

/// Whether on-device speech recognition is ready.
public enum SpeechModelStatus: Sendable, Equatable {
    /// Apple's SpeechTranscriber model for the locale is installed.
    case ready
    /// The model is downloading.
    case downloading
    /// Supported, but not downloaded yet.
    case notInstalled
    /// SpeechTranscriber can't run here; the older recognizer is used if it works on-device.
    case unsupported
}

/// Transcribes one turn of the wearer's voice on the iPhone and decides when they've finished speaking.
///
/// Engine: the owner's choice (`SpeechProvider`, through `SpeechRecognition.choice`), such as ElevenLabs Scribe v2
/// Realtime (`ScribeEngine`), when it can take the request; otherwise, and as its stand-in, the default:
/// Apple's `SpeechAnalyzer` with a `SpeechTranscriber` (iOS 26, on-device, English: en-US or en-GB etc. from
/// the device's locale), fed the glasses' 16 kHz mono Int16 audio, converted to the analyzer's preferred format.
/// Fallback: `SFSpeechRecognizer` with on-device recognition required, when the transcriber or its model isn't there.
///
/// End of speech is decided on the audio received, not the clock: the glasses' microphone arrives in bursts (in one
/// capture its first chunk, then nothing for 3.6 s, then 5 s of audio within half a second).
/// - After speech has started (words beyond the wake phrase): about 1 s of silence **in the audio itself**, measured
///   by a small voice-activity detector against the running noise floor; 1.6 s when the words so far sound
///   unfinished ("…tell me about", "play me some"). With noise the detector can't classify as silence, the
///   transcriber falls back to 2 s without a transcript change. This leaves time for recognizers that report
///   updates about once a second.
/// - A delivery gap alone ends the request only after 4 s with no audio at all; or the glasses end the microphone.
/// - After a wake word: nothing said within 8 s of audio (12 s by the clock at most) ends the turn with no text.
///   In a follow-up window: no voice within the window (5 s by the clock) ends it; a voice that starts in time gets
///   4 s more to become words. 120 s of audio (124 s by the clock) is the most one request gets.
/// A leading wake phrase ("Hey Meta") is dropped from the text, and the wake phrase alone is no speech.
/// Text never reaches the log; only lengths and timings do.
public final class Transcriber: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// The first words (beyond the wake phrase) were recognised.
        case speechStarted
        /// The wearer finished. `text` is empty when nothing was understood, or only the wake phrase.
        case ended(text: String, reason: EndReason)
    }

    public enum EndReason: String, Sendable {
        case silence = "audio silence"
        case micEnded = "mic ended"
        case micStalled = "mic stalled 4 s"
        case noSpeech = "no speech"
        case tooLong = "too long"
        /// Long speech ended at a sentence end (`Settings.sentenceCutAfter`, the live interpreter).
        case sentenceCut = "sentence end in long speech"
        /// Long speech reached `Settings.speechCap` (the live interpreter).
        case speechCap = "long speech cap"
        case unavailable
        case cancelled
    }

    public enum Mode: Sendable, Equatable {
        /// Opened by a wake word: the audio starts with it (and a little from before it).
        case afterWake
        /// A follow-up window after a reply: no wake word, and the wearer may say nothing at all.
        case followUp(window: TimeInterval)
    }

    public struct Settings: Sendable {
        public var mode: Mode = .afterWake
        /// Silence in the audio, once speech has started, that ends the request.
        public var endSilence: TimeInterval = 1.0
        /// The same when the words so far sound unfinished.
        public var endSilenceUnfinished: TimeInterval = 1.6
        /// Once speech has run this long (outside the live interpreter), give the wearer `longDictationSilence` to
        /// breathe and think between sentences without cutting the turn off.
        public var longDictationAfter: TimeInterval = 8
        public var longDictationSilence: TimeInterval = 3.0
        /// Received audio with no transcript change that ends the request (fallback for noise).
        public var transcriptQuiet: TimeInterval = 2.0
        public var noSpeechTimeout: TimeInterval = 8
        /// In a follow-up window, how long a voice that started in time has to turn into words.
        public var followUpGrace: TimeInterval = 4
        public var maxDuration: TimeInterval = 120
        /// In a follow-up window, speech whose loudest moment stays below this isn't the wearer (a TV, people nearby):
        /// it's ignored. The wearer's own voice reaches about -28 dB in the glasses' microphone; background talk
        /// picked up in tests peaked at -54 dB. The live interpreter lowers it: the other person isn't the wearer.
        public var followUpMinimumDB: Double = -45
        /// The language ElevenLabs listens for (ISO 639-1). Nil: it works out each request's language and reports it
        /// in `detectedLanguage` (the live interpreter). Apple's recognizer always listens in English.
        public var language: String? = "en"
        /// Long speech (the live interpreter; off by default): once speech has run this long, the request ends at the
        /// next sentence end in the transcript followed by `sentenceCutPause` of quiet, so a monologue arrives in
        /// pieces instead of one translation of 30 s.
        public var sentenceCutAfter: TimeInterval?
        public var sentenceCutPause: TimeInterval = 0.3
        /// Long speech ends here at the latest (off by default).
        public var speechCap: TimeInterval?

        public init(mode: Mode = .afterWake) {
            self.mode = mode
        }
    }

    /// Timings of one request, for the log and the live interpreter. No text.
    public struct Diagnostics: Sendable, Codable {
        /// Empty.
        public init() {}
        public var engine = ""
        public var audioSeconds: Double = 0
        public var speechStartedAtAudio: Double?
        public var endedAtAudio: Double?
        public var reason = ""
        public var noiseFloorDB: Double = 0
        public var loudestDB: Double = -120
        /// Audio time of each transcript change and the transcript's length then.
        public var updates: [Update] = []

        public struct Update: Sendable, Codable {
            public var atAudio: Double
            public var characters: Int
        }
    }

    /// No audio at all for this long, once speech started, ends the request; a shorter delivery gap is waited out.
    /// Also the clock's slack on the no-speech and length limits, which are otherwise measured in audio.
    static let stallLimit: TimeInterval = 4

    public let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let settings: Settings
    private let lock = NSLock()
    private let watch = Stopwatch()

    // State (under `lock`).
    private var engine: RecognitionEngine?
    private var pending: [[Int16]] = []
    private var finals: [String] = []
    private var volatile = ""
    private var started = false
    private var ended = false
    /// No more results are taken: cancelled, or the final text has been read. Results that arrive after the end of
    /// speech was decided, while the engine finishes, still count: the last word is often in them.
    private var closed = false
    private var lastChange = Date()
    private var lastAudio = Date()
    private var totalSamples = 0
    /// Received audio, counted at most at real-time pace (advanced by `tick`); caught up to everything received
    /// whenever the transcript changes, since the recognizer evidently heard it.
    private var heardSamples = 0
    /// `heardSamples` at the last transcript change: what's been heard since is the trailing silence.
    private var heardAtChange = 0
    private var lastTick = Date()
    private var startDate = Date()
    private var timer: Task<Void, Never>?
    /// The microphone ended before the engine was ready: finish once the buffered audio is in.
    private var micEndedEarly = false
    private var voice = VoiceActivity()
    private var diagnosticsStore = Diagnostics()
    private var detected: String?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        (events, eventContinuation) = AsyncStream<Event>.makeStream()
    }

    // MARK: Model

    /// The English locale to transcribe in: the device's own English variant, else US English.
    public static func preferredLocale() -> Locale {
        let current = Locale.current
        if current.language.languageCode?.identifier == "en" { return current }
        return Locale(identifier: "en-US")
    }

    /// The SpeechTranscriber locale for `preferredLocale()`, or nil when it isn't supported.
    static func transcriberLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale()) { return locale }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    public static func modelStatus() async -> SpeechModelStatus {
        guard let locale = await transcriberLocale() else { return .unsupported }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .downloading: return .downloading
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads the model if it's missing. Returns once it's installed (or straight away if it already was).
    public static func installModel() async throws {
        guard let locale = await transcriberLocale() else { return }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        AssistantLog.add("Speech model: downloading")
        let watch = Stopwatch()
        try await request.downloadAndInstall()
        AssistantLog.add("Speech model: installed in \(watch.elapsed.seconds)")
    }

    /// Whether the older on-device recognizer can stand in.
    static var fallbackRecognizerUsable: Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: preferredLocale()) else { return false }
        return recognizer.supportsOnDeviceRecognition && recognizer.isAvailable
    }

    // MARK: Turn

    /// Starts recognising. Audio appended before this finishes is kept and fed in once the engine is ready.
    /// Returns false when no engine can run (no model and no on-device fallback); `events` then ends at once.
    @discardableResult
    public func start() async -> Bool {
        // The chosen recognizer when it can take the request (ElevenLabs hands over to the iPhone's recognizer by
        // itself if it fails part-way), else the iPhone's.
        let provider = SpeechRecognition.choice
        let request = RecognitionRequest(owner: self, language: settings.language) { [weak self] in
            await self?.makeOnDeviceEngine()
        }
        var made = await provider.makeEngine(request)
        if made == nil, provider != .iPhone { made = await makeOnDeviceEngine() }
        guard let chosen = made else {
            AssistantLog.add("Speech: no on-device recognizer is ready")
            finish(reason: .unavailable)
            return false
        }
        let backlog: [[Int16]]? = lock.withLock {
            if ended { return nil }
            engine = chosen
            startDate = Date()
            lastAudio = Date()
            lastTick = Date()
            defer { pending.removeAll() }
            return pending
        }
        guard let backlog else {
            // Cancelled (or the turn closed) while the engine was getting ready.
            chosen.cancel()
            return false
        }
        AssistantLog.add("Speech: \(chosen.name) ready after \(watch.elapsed.seconds)")
        for samples in backlog { chosen.append(samples) }
        let timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
        let endNow: Bool = lock.withLock {
            // Ended while the backlog was fed in (micEnded, cancel or the engine stopping saw no timer to cancel).
            guard !ended else {
                timer.cancel()
                return false
            }
            self.timer = timer
            return micEndedEarly
        }
        if endNow { finish(reason: .micEnded) }
        return true
    }

    /// Apple's recognizer on this iPhone: SpeechTranscriber when its model is installed, else the older on-device
    /// SFSpeechRecognizer. Also ElevenLabs' stand-in.
    private func makeOnDeviceEngine() async -> RecognitionEngine? {
        if let locale = await Self.transcriberLocale(), await Self.modelStatus() == .ready,
           let engine = await AnalyzerEngine.make(locale: locale, owner: self) {
            return engine
        }
        return Self.fallbackRecognizerUsable ? RecognizerEngine.make(locale: Self.preferredLocale(), owner: self) : nil
    }

    /// The glasses' microphone: 16 kHz mono Int16.
    public func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let target: RecognitionEngine? = lock.withLock {
            guard !ended else { return nil }
            totalSamples += samples.count
            lastAudio = Date()
            voice.process(samples)
            if engine == nil { pending.append(samples) }
            return engine
        }
        target?.append(samples)
    }

    /// The glasses stopped the microphone: finish with what was heard.
    public func micEnded() {
        let waitForEngine: Bool = lock.withLock {
            guard engine == nil, !ended else { return false }
            micEndedEarly = true
            return true
        }
        if !waitForEngine { finish(reason: .micEnded) }
    }

    public func cancel() {
        let target: RecognitionEngine? = lock.withLock {
            closed = true
            guard !ended else { return nil }
            ended = true
            timer?.cancel()
            return engine
        }
        target?.cancel()
        eventContinuation.finish()
    }

    // MARK: From the engines

    /// A recognition result: `text` replaces the volatile tail, or, when final, is appended to the finished text.
    func update(_ text: String, isFinal: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSpeech: Bool = lock.withLock {
            guard !closed else { return false }
            let before = transcriptLocked
            if isFinal {
                if !cleaned.isEmpty { finals.append(cleaned) }
                volatile = ""
            } else {
                volatile = cleaned
            }
            if transcriptLocked != before {
                lastChange = Date()
                heardSamples = totalSamples
                heardAtChange = totalSamples
                if diagnosticsStore.updates.count < 300 {
                    diagnosticsStore.updates.append(.init(atAudio: Double(totalSamples) / PCM.micRate,
                                                          characters: transcriptLocked.count))
                }
            }
            // The wake phrase (or the start of one) isn't the request: speech starts with the first word after it.
            guard !ended, !started, !requestText(transcriptLocked).isEmpty else { return false }
            started = true
            diagnosticsStore.speechStartedAtAudio = Double(totalSamples) / PCM.micRate
            return true
        }
        if firstSpeech {
            AssistantLog.add("Speech started after \(watch.elapsed.seconds)")
            eventContinuation.yield(.speechStarted)
        }
    }

    /// The engine stopped by itself (an error, or the recognizer ended).
    func engineStopped(_ reason: String) {
        AssistantLog.add("Speech: \(reason)")
        finish(reason: lock.withLock { started } ? .silence : .noSpeech)
    }

    /// ElevenLabs' detected language for this request (only when `Settings.language` is nil).
    func languageDetected(_ code: String) {
        lock.withLock { if !closed { detected = code } }
    }

    /// The language ElevenLabs detected, as it spells it ("fra", "en", …): set when `Settings.language` is nil and
    /// ElevenLabs heard the request (complete once `events` has ended). Nil otherwise, including when Apple's
    /// recognizer stood in.
    public var detectedLanguage: String? {
        lock.withLock { detected }
    }

    // MARK: Private

    private var transcriptLocked: String {
        (finals + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ")
    }

    private func tick() {
        let now = Date()
        let decision: EndReason? = lock.withLock {
            guard !ended, engine != nil else { return nil }
            let rate = PCM.micRate
            // A burst is handed to the recognizer at once but counts as heard at real-time pace, so 0.7 s of it
            // landing within one tick can't end the request before the recognizer has reported it.
            heardSamples = min(totalSamples, heardSamples + Int(max(0, now.timeIntervalSince(lastTick)) * rate))
            lastTick = now
            let waited = now.timeIntervalSince(startDate)
            if Double(totalSamples) > settings.maxDuration * rate || waited > settings.maxDuration + Self.stallLimit {
                return .tooLong
            }
            if !started {
                switch settings.mode {
                case .afterWake:
                    let heardNothing = Double(heardSamples) > settings.noSpeechTimeout * rate
                        && waited > settings.noSpeechTimeout
                    return heardNothing || waited > settings.noSpeechTimeout + Self.stallLimit ? .noSpeech : nil
                case .followUp(let window):
                    // A voice that started within the window claims it and gets a little longer to become words.
                    let limit = voice.voiced ? window + settings.followUpGrace : window
                    return waited > limit ? .noSpeech : nil
                }
            }
            let spoken = diagnosticsStore.speechStartedAtAudio.map {
                Double(totalSamples) / rate - max(0, $0 - Self.recognitionLag)
            } ?? 0
            let isLongDictation = settings.sentenceCutAfter == nil && spoken >= settings.longDictationAfter
            let unfinished = Self.soundsUnfinished(requestText(transcriptLocked))
            let needed: TimeInterval
            if isLongDictation {
                needed = unfinished ? max(settings.longDictationSilence + 0.5, settings.endSilenceUnfinished)
                                    : max(settings.longDictationSilence, settings.endSilence)
            } else {
                needed = unfinished ? settings.endSilenceUnfinished : settings.endSilence
            }
            // Detector silence counts only if the detector heard the request itself as voice (from about a second
            // before its first words were recognised). If the speech never crossed its thresholds (a quiet mic, a
            // loud street), the silence count would already be long and cut the request after a word or two; the
            // "no new words" rule below decides then.
            let voiceStart = (diagnosticsStore.speechStartedAtAudio ?? .infinity) - Self.recognitionLag
            let heardRequestAsVoice = voice.voiced
                && Double(totalSamples - voice.silenceSamples) / rate >= voiceStart
            if heardRequestAsVoice, Double(voice.silenceSamples) >= needed * rate { return .silence }
            // Long speech (only when the settings ask for it): a sentence end with a short pause, or the cap.
            if settings.sentenceCutAfter != nil || settings.speechCap != nil,
               diagnosticsStore.speechStartedAtAudio != nil {
                if let cap = settings.speechCap, spoken >= cap { return .speechCap }
                if let after = settings.sentenceCutAfter, spoken >= after,
                   Self.endsSentence(requestText(transcriptLocked)) {
                    let paused = heardRequestAsVoice
                        && Double(voice.silenceSamples) >= settings.sentenceCutPause * rate
                    // When the detector can't call the pause (noise), no new words for a little longer will do.
                    let noNewWords = Double(heardSamples - heardAtChange) >= (settings.sentenceCutPause + 0.5) * rate
                    if paused || noNewWords { return .sentenceCut }
                }
            }
            let quietLimit = max(settings.transcriptQuiet, needed + 1.0)
            let transcriptQuiet = Double(heardSamples - heardAtChange) >= quietLimit * rate
            if transcriptQuiet, now.timeIntervalSince(lastChange) >= quietLimit { return .silence }
            if now.timeIntervalSince(lastAudio) >= Self.stallLimit { return .micStalled }
            return nil
        }
        if let decision { finish(reason: decision) }
    }

    private func finish(reason: EndReason) {
        let target: RecognitionEngine?
        let isFirst: Bool = lock.withLock {
            guard !ended else { return false }
            ended = true
            timer?.cancel()
            return true
        }
        guard isFirst else { return }
        target = lock.withLock { engine }
        let audioSeconds = Double(lock.withLock { totalSamples }) / PCM.micRate
        Task {
            if let target { await target.finish() }
            let (heard, loudest): (String, Double) = self.lock.withLock {
                self.closed = true
                return (self.transcriptLocked, self.voice.loudestDB)
            }
            var text = self.requestText(heard)
            var ignoredAsBackground = false
            if case .followUp = self.settings.mode, !text.isEmpty, loudest < self.settings.followUpMinimumDB {
                ignoredAsBackground = true
                AssistantLog.add("Speech: follow-up too quiet to be the wearer (loudest \(Int(loudest.rounded())) dB); ignored")
                text = ""
            }
            let cadence: String = self.lock.withLock {
                self.diagnosticsStore.audioSeconds = audioSeconds
                self.diagnosticsStore.endedAtAudio = audioSeconds
                self.diagnosticsStore.reason = reason.rawValue
                self.diagnosticsStore.engine = self.engine?.name ?? "none"
                self.diagnosticsStore.noiseFloorDB = (self.voice.floorDB * 10).rounded() / 10
                self.diagnosticsStore.loudestDB = (self.voice.loudestDB * 10).rounded() / 10
                let times = self.diagnosticsStore.updates.map(\.atAudio)
                let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
                let levels = String(format: "floor %.0f dB, loudest %.0f dB, voice %@", self.voice.floorDB,
                                    self.voice.loudestDB, self.voice.voiced ? "heard" : "not heard")
                guard !gaps.isEmpty else { return "no transcript updates; \(levels)" }
                return "\(times.count) transcript updates, median gap \(String(format: "%.2f", gaps[gaps.count / 2])) s; \(levels)"
            }
            AssistantLog.add("Speech ended (\(reason.rawValue)): \(text.count) characters from "
                             + "\(String(format: "%.1f", audioSeconds)) s of audio, \(self.watch.elapsed.seconds) after the "
                             + "\(self.settings.mode == .afterWake ? "wake" : "window opened"); \(cadence)")
            if text.isEmpty, !heard.isEmpty, !ignoredAsBackground {
                AssistantLog.add("Speech: only the wake phrase; treated as no speech")
            }
            self.eventContinuation.yield(.ended(text: text, reason: reason))
            self.eventContinuation.finish()
        }
    }

    /// This request's timings so far (complete once `events` has ended).
    public var diagnostics: Diagnostics {
        lock.withLock { diagnosticsStore }
    }

    /// Words that rarely end a request: when the transcript stops on one, the wearer is probably mid-sentence.
    private static let continuingWords: Set<String> = [
        "a", "an", "the", "about", "to", "and", "or", "but", "for", "of", "with", "some", "me", "my", "your", "in",
        "on", "at", "from", "by", "into", "is", "are", "was", "what", "what's", "whats", "who", "how", "where", "when",
        "which", "play", "tell", "set", "remind", "add", "find", "like", "so", "if", "than", "because", "this", "that",
        "um", "uh", "er",
    ]

    /// Whether `text` ends a sentence: its last mark is a full stop, question or exclamation mark (any script).
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last(where: { $0 != "\"" && $0 != "”"
            && $0 != "»" && $0 != "'" && $0 != ")" }) else { return false }
        return ".!?…。！？؟।".contains(last)
    }

    /// Whether `request` sounds unfinished: it ends on a continuing word, or it's only a word or two so far.
    static func soundsUnfinished(_ request: String) -> Bool {
        let words = request.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard let last = words.last else { return true }
        return words.count <= 2 || continuingWords.contains(last)
    }

    // MARK: Wake phrase

    private static let wakeGreeting = #"(?:hey|hi|ok|okay|o\.\s?k\.?)"#
    /// Including how the recognizer has misheard "Meta" ("Hey Ma", "Hey Mera", "Hey, Madam"), and the app's own name.
    private static let wakeName = #"(?:meta|mata|metta|matta|meda|mehta|mera|mea|ma|mam|ma'am|madam|mela|re{1,2}[\s-]*glass)"#
    private static let notWord = #"(?![\p{L}\p{N}])"#
    /// "Hey Meta", "Hey, Meta." ... at the start, with the punctuation and spaces after it. "Hira" is "Hey Meta"
    /// run together.
    private static let wakePrefix = #"^[\s\p{P}]*(?:"# + wakeGreeting + #"[\s\p{P}]*"# + wakeName + #"|hira|hiram)"#
        + notWord + #"[\s\p{P}]*"#
    /// Nothing but (the start of) a wake phrase: "", "OK", "Hey Meta", "Meta."
    private static let wakeOnly = #"^[\s\p{P}]*(?:"# + wakeGreeting + notWord + #")?[\s\p{P}]*(?:"# + wakeName + notWord
        + #")?[\s\p{P}]*$"#

    /// How long the recogniser takes to report a word after it was said, roughly.
    private static let recognitionLag: Double = 1.0

    /// The request as this transcriber's mode reads it. After a wake word, "OK" or "Hey" alone is the start of the
    /// wake phrase and counts as nothing; in a follow-up window there's no wake word, so "OK" is an answer.
    private func requestText(_ transcript: String) -> String {
        switch settings.mode {
        case .afterWake: return Self.request(from: transcript)
        case .followUp:
            let text = Self.request(from: transcript, wakeOnlyIsEmpty: false)
            return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
        }
    }

    /// The request without a leading wake phrase ("Hey Meta", however the recognizer spelled it). Empty
    /// when nothing else was said: the wake phrase, or the start of one ("OK", "Hey"), alone (unless
    /// `wakeOnlyIsEmpty` is false).
    static func request(from transcript: String, wakeOnlyIsEmpty: Bool = true) -> String {
        var text = transcript
        for _ in 0..<3 {
            guard let found = text.range(of: wakePrefix, options: [.regularExpression, .caseInsensitive]) else { break }
            text = String(text[found.upperBound...])
        }
        if wakeOnlyIsEmpty, text.range(of: wakeOnly, options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Voice activity

/// A small energy-based voice-activity detector over the glasses' 16 kHz audio, in 20 ms frames. The noise floor
/// follows the quietest frames at once and rises slowly (about 1 dB a second), so steady noise such as a car becomes
/// the floor. A frame is voice when it's 10 dB above the floor (and above -58 dBFS); two voice frames in a row reset
/// the trailing silence.
struct VoiceActivity {
    static let frame = 320
    static let marginDB = 10.0
    static let minimumDB = -58.0
    static let floorRisePerFrame = 0.02

    private(set) var floorDB = -60.0
    private(set) var loudestDB = -120.0
    /// Received audio since the last voice, in samples.
    private(set) var silenceSamples = 0
    /// A voice was heard at some point.
    private(set) var voiced = false
    private var started = false
    private var run = 0
    private var partial: [Int16] = []

    mutating func process(_ samples: [Int16]) {
        var index = 0
        if !partial.isEmpty {
            let need = Self.frame - partial.count
            partial.append(contentsOf: samples.prefix(need))
            index = min(need, samples.count)
            guard partial.count == Self.frame else { return }
            frame(partial[...])
            partial.removeAll(keepingCapacity: true)
        }
        while index + Self.frame <= samples.count {
            frame(samples[index..<(index + Self.frame)])
            index += Self.frame
        }
        if index < samples.count { partial.append(contentsOf: samples[index...]) }
    }

    private mutating func frame(_ samples: ArraySlice<Int16>) {
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        let level = 20 * log10(max(rms, 1) / 32768)
        loudestDB = max(loudestDB, level)
        if !started {
            started = true
            floorDB = level
        } else if level < floorDB {
            floorDB = level
        } else {
            floorDB += Self.floorRisePerFrame
        }
        if level > floorDB + Self.marginDB, level > Self.minimumDB {
            run += 1
            if run >= 2 {
                voiced = true
                silenceSamples = 0
                return
            }
        } else {
            run = 0
        }
        silenceSamples += samples.count
    }
}

// MARK: - Engines

/// One request's recognizer. Every engine keeps this contract; `SpeechProvider` lists the ones the owner can choose,
/// and docs/VOICE.md shows the shape of a new one.
///
/// - **Audio in:** `append` gets the glasses' microphone as 16 kHz mono signed 16-bit PCM (`PCM.micRate`), in order,
///   from the start of the request (the wake phrase and a moment before it). It arrives in bursts, not in real time,
///   and may come before the engine is connected: keep it, never drop it. `append` must return at once.
/// - **Results out:** report text to the `Transcriber` that made the engine (`RecognitionRequest.owner`) with
///   `update(_:isFinal:)`. A result that isn't final replaces the unfinished tail; a final one is added to the text so
///   far. Report as often as the recognizer has something: the transcriber watches the words to tell an unfinished
///   sentence. Leave the wake phrase in; the transcriber removes it.
/// - **The end:** the transcriber decides when the wearer has finished (its own silence detection), so turn any
///   end-of-speech detection of the service off. It then calls `finish()`: send what's left, wait briefly (about
///   1.5 s at most) for the last results, and return. It must never hang.
/// - **Cancellation:** `cancel()` stops at once (a new wake word, the glasses closing the turn): close the connection,
///   report nothing more.
/// - **Errors:** never throw. If the service fails before the end, hand the request to the iPhone's recognizer
///   (`RecognitionRequest.standIn`), replaying what was heard so far, as `ScribeEngine` does; or call
///   `engineStopped(_:)` with a log-safe reason and the request ends with what was heard.
/// - **Language:** when the request asks for none (`language` nil), report the one heard with `languageDetected(_:)`.
/// - **Privacy:** never log the text or the audio. Kinds, sizes and timings only (`AssistantLog`).
protocol RecognitionEngine: AnyObject, Sendable {
    /// Log-safe, and may change as the engine goes ("… (connected in 0.4 s)").
    var name: String { get }
    /// 16 kHz mono Int16.
    func append(_ samples: [Int16])
    /// Ends the input and waits (briefly) for the final results.
    func finish() async
    func cancel()
}

/// SpeechAnalyzer + SpeechTranscriber.
private final class AnalyzerEngine: RecognitionEngine, @unchecked Sendable {
    let name = "SpeechTranscriber"
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: StreamingConverter?
    private let format: AVAudioFormat
    private var results: Task<Void, Never>?
    private let lock = NSLock()

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.analyzer = analyzer
        self.input = input
        self.format = format
        self.converter = Self.sameFormat(format, PCM.micFormat) ? nil : StreamingConverter(output: format)
    }

    static func make(locale: Locale, owner: Transcriber) async -> AnalyzerEngine? {
        // No `.fastResults`: Apple documents it as faster but less accurate, and accuracy is what's short.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                   considering: PCM.micFormat) ?? PCM.micFormat
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AnalyzerEngine(analyzer: analyzer, input: continuation, format: format)
        do {
            // Words the recogniser should expect: the wake phrases (so they're recognised, and then removed).
            let context = AnalysisContext()
            context.contextualStrings = [.general: ["Hey Meta", "Meta", "ReGlass"]]
            try? await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            AssistantLog.add("Speech: SpeechAnalyzer couldn't start (\(type(of: error)))")
            continuation.finish()
            return nil
        }
        engine.results = Task { [weak owner] in
            do {
                for try await result in transcriber.results {
                    owner?.update(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch is CancellationError {
            } catch {
                owner?.engineStopped("SpeechTranscriber stopped (\(type(of: error)))")
            }
        }
        return engine
    }

    func append(_ samples: [Int16]) {
        guard let buffer = PCM.buffer(samples, format: PCM.micFormat) else { return }
        let ready: AVAudioPCMBuffer? = lock.withLock { converter.map { $0.convert(buffer) } ?? buffer }
        if let ready { input.yield(AnalyzerInput(buffer: ready)) }
    }

    func finish() async {
        if let tail = lock.withLock({ converter?.flush() }) { input.yield(AnalyzerInput(buffer: tail)) }
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            AssistantLog.add("Speech: finalizing failed (\(type(of: error)))")
        }
        // The results sequence ends once the analyzer has finished; don't wait for ever.
        let results = self.results
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await results?.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(1500)) }
            await group.next()
            group.cancelAll()
        }
    }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private static func sameFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.commonFormat == b.commonFormat && a.channelCount == b.channelCount
            && a.isInterleaved == b.isInterleaved
    }
}

/// The older SFSpeechRecognizer, on-device only.
private final class RecognizerEngine: RecognitionEngine, @unchecked Sendable {
    let name = "SFSpeechRecognizer (on-device)"
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let converter: StreamingConverter
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var finalWaiter: CheckedContinuation<Void, Never>?
    private var gotFinal = false

    private init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        converter = StreamingConverter(output: request.nativeAudioFormat)
    }

    static func make(locale: Locale, owner: Transcriber) -> RecognizerEngine? {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        let engine = RecognizerEngine(recognizer: recognizer)
        engine.task = recognizer.recognitionTask(with: engine.request) { [weak owner, weak engine] result, error in
            if let result {
                owner?.update(result.bestTranscription.formattedString, isFinal: false)
                if result.isFinal { engine?.markFinal() }
            }
            if error != nil {
                engine?.markFinal()
            }
        }
        return engine
    }

    func append(_ samples: [Int16]) {
        guard let buffer = PCM.buffer(samples, format: PCM.micFormat) else { return }
        if let converted = lock.withLock({ converter.convert(buffer) }) { request.append(converted) }
    }

    func finish() async {
        if let tail = lock.withLock({ converter.flush() }) { request.append(tail) }
        request.endAudio()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if gotFinal { return true }
                finalWaiter = continuation
                return false
            }
            if now { continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.markFinal() }
        }
    }

    func cancel() {
        task?.cancel()
        markFinal()
    }

    private func markFinal() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            gotFinal = true
            defer { finalWaiter = nil }
            return finalWaiter
        }
        waiter?.resume()
    }
}
