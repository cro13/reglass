import AVFoundation
import Foundation
import ReGlassAssistant
import NaturalLanguage

/// What the interpreter needs from the voice turn it runs in. `AssistantController` builds one for an open turn and
/// hands the turn over (see its `interpret(_:language:greet:)`).
@MainActor
struct InterpreterHost {
    /// Opens a fresh transcriber with `settings` on the turn's live microphone audio and runs it to its end. Nil when
    /// no recognizer could start.
    let listen: @MainActor (Transcriber.Settings) async -> InterpreterHeard?
    /// Ends the current listening at once (Stop on the screen).
    let stopListening: @MainActor () -> Void
    /// Tells the glasses the words were understood: they wait while ReGlass translates.
    let understood: @MainActor (String) async -> Void
    /// Plays audio into the turn on the glasses; the microphone opens again once it has played. False when it didn't
    /// play (the turn or the link went away).
    let speak: @MainActor (AsyncThrowingStream<[Int16], Error>) async -> Bool
    let setPhase: @MainActor (AssistantController.Phase) -> Void
    /// The turn ended from outside: a new wake word, the glasses closed it, the link dropped.
    let isStopped: @MainActor () -> Bool
}

/// One utterance as heard.
struct InterpreterHeard {
    let text: String
    let diagnostics: Transcriber.Diagnostics
}

/// The live interpreter (experimental): the other person speaks their language, and ReGlass tells the wearer in
/// English, through the glasses. It translates one way only. The wearer's own English is recognised and left alone.
///
/// - **Needs** (`blocker()`): an ElevenLabs key and ElevenLabs as ReGlass's speech recognition (Scribe hears the
///   other person, locked to their language), the Claude key (Claude translates), and no phone call going on. By
///   voice, the Interpreter connector must also be on (it's off until the owner switches it on).
/// - **Start:** by voice ("Hey Meta, interpreter, French": ReGlass matches the request itself, or Claude calls
///   `start_interpreter`; once "Interpreting French. Go ahead." has played, the turn is handed here), or Start on its
///   screen.
/// - **Real time** (a setting, on by default; `InterpreterRealTime.swift`): ReGlass keeps listening while the voice
///   talks, and each sentence is translated as soon as it's said. Start begins at once.
/// - **Taking turns** (Real time off, or a voice start that real time couldn't take): the screen's Start waits for the
///   next "Hey Meta" (five minutes at most). Then the glasses' assistant microphone, in follow-up windows over and over
///   with no limit: after each translation the glasses listen again. Each listen is transcribed in the other person's
///   language (Scribe, locked to it). If Scribe can't be reached for a listen, the speech recognition's stand-in, Apple's
///   English recognizer, hears it instead.
/// - **English is left alone:** three words or more that Apple's language recognizer is sure are English (`isAlreadyEnglish`)
///   are the wearer's, and aren't translated. Everything else is translated into English.
/// - **Loudness gate:** −60 dB instead of the follow-up window's −45 dB. The other person isn't the wearer: facing the
///   wearer, their voice reaches the glasses' microphones roughly 20–30 dB below the wearer's own (about −28 dB), so
///   −45 dB would drop much of what they say. −60 dB sits just under the voice detector's own floor (−58 dB). The
///   cost: in a loud room, nearby voices can be picked up and translated.
/// - **Translate:** `InterpreterTranslator` (Claude Haiku 5.5, its own short prompt, quick settings), streamed into the
///   assistant's voice sentence by sentence.
/// - **Stop:** "stop interpreting" (or "Hey Meta, stop"), Stop on the screen, five minutes without speech, or the turn
///   ending (glasses off, a new wake word). The voice says "Interpreter off." when the turn is still open.
/// - **Chats:** each session is one conversation: their words and each translation.
/// - **Long speech:** once someone has spoken for about 3 s, the listen ends at the next sentence end (7.5 s at most),
///   so a monologue is translated in pieces instead of all at once.
///
/// The activity log gets counts and languages only; never what was said or its translation.
@MainActor
final class InterpreterSession: ObservableObject {
    static let shared = InterpreterSession()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        /// What the other person said. Grows as live clauses of the same utterance arrive.
        var original: String
        /// Grows as the translation streams in.
        var translation = ""
        var failed = false
        var done = false
        /// Real time: the voice is saying this one's translation now.
        var playing = false
    }

    enum Status: Equatable {
        case off
        /// Started on the screen: the next "Hey Meta" begins.
        case waitingForWake
        case starting
        case listening
        case translating
        case speaking
        case ending
    }

    // Set only by the session (this file and InterpreterRealTime.swift).
    @Published var status: Status = .off
    /// The other person's language, for the session going on or about to start.
    @Published var language: InterpreterLanguage?
    /// This session's lines (the last session's, once it's over), oldest first.
    @Published var lines: [Line] = []
    /// One plain line about how the last session ended.
    @Published var endNote: String?
    /// Real time: what's being heard right now, before it's a line ("" between sentences).
    @Published var partial = ""
    /// The session going on (or the last one) runs in real time.
    @Published var isRealTimeSession = false
    /// The setting: keep listening while the voice talks, translating sentence by sentence.
    @Published private(set) var realTime: Bool
    /// Real time is on but iOS's microphone permission is off (the iPhone's microphone is real time's fallback).
    @Published private(set) var micDenied = false
    /// When the screen's Start stops waiting for "Hey Meta".
    @Published private(set) var waitingUntil: Date?
    /// The screen's language, remembered.
    @Published var chosen: InterpreterLanguage {
        didSet { UserDefaults.standard.set(chosen.code, forKey: Self.chosenKey) }
    }

    var isRunning: Bool {
        switch status {
        case .off, .waitingForWake: return false
        default: return true
        }
    }

    static let closingLine = "Interpreter off."
    /// How long each listen waits for someone to start speaking before listening again.
    static let window: TimeInterval = 20
    /// No speech for this long ends the session.
    static let silenceLimit: TimeInterval = 5 * 60
    /// The follow-up window's loudness gate, lowered for the other person (see above).
    static let minimumDB: Double = -60
    /// How long the screen's Start waits for "Hey Meta".
    static let waitForWake: TimeInterval = 5 * 60

    private static let chosenKey = "reglass.interpreter.language"
    private static let realTimeKey = "reglass.interpreter.continuousRealTime"

    let log: ActivityLog
    let translator: InterpreterTranslator
    var voiceRequest: (language: InterpreterLanguage, at: Date)?
    private var waitTimer: Task<Void, Never>?
    var stopRequested = false
    private var stopCurrentListen: (() -> Void)?
    /// The last session ended because its turn ended from outside (perhaps a new "Hey Meta").
    var endedFromOutsideAt: Date?
    var generation = 0
    /// The real-time session going on.
    var realTimeRun: InterpreterRealTimeRun?
    /// The language to go on with when the "keep interpreting" notification is tapped (the glasses stopped listening).
    var continueLanguage: InterpreterLanguage?

    private init() {
        let log = GlassesController.shared.log
        self.log = log
        translator = InterpreterTranslator(log: { log.add($0) })
        let saved = UserDefaults.standard.string(forKey: Self.chosenKey).flatMap(InterpreterLanguage.named)
        chosen = saved ?? .french
        realTime = UserDefaults.standard.object(forKey: Self.realTimeKey) as? Bool ?? true
    }

    /// The assistant's voice, in English: the only language the interpreter speaks. Apple's voice stands in when
    /// ElevenLabs can't be reached.
    nonisolated static func makeVoice() -> ElevenLabsVoice { ElevenLabsVoice(fallback: AppleVoice()) }

    // MARK: Real time, the setting

    /// Turns Real time on or off. On asks for the microphone permission (ReGlass is on screen: the switch is).
    func setRealTime(_ on: Bool) async {
        guard on else {
            setRealTimeValue(false)
            micDenied = false
            return
        }
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .undetermined:
            granted = await AVAudioApplication.requestRecordPermission()
            log.add("Interpreter: microphone permission \(granted ? "given" : "not given")")
        default:
            granted = false
        }
        micDenied = !granted
        setRealTimeValue(granted)
    }

    /// Start was tapped: with Real time on (the default) and the microphone never asked for, iOS asks now, so the
    /// iPhone's microphone can stand in during the session. Never on merely opening a screen.
    func askForMicrophoneIfNeeded() async {
        if realTime, AVAudioApplication.shared.recordPermission == .undetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            log.add("Interpreter: microphone permission \(granted ? "given" : "not given")")
        }
        refreshMicrophonePermission()
    }

    /// After a visit to iPhone Settings: the microphone line follows what iOS says now.
    func refreshMicrophonePermission() {
        let permission = AVAudioApplication.shared.recordPermission
        if micDenied, permission == .granted { micDenied = false }
        if realTime, permission == .denied { micDenied = true }
    }

    private func setRealTimeValue(_ on: Bool) {
        guard realTime != on else { return }
        realTime = on
        UserDefaults.standard.set(on, forKey: Self.realTimeKey)
        log.add("Interpreter: real time \(on ? "on" : "off")")
    }

    /// The screen's Start: with Real time on, it starts at once; otherwise the next "Hey Meta" begins it.
    func startFromScreen(_ language: InterpreterLanguage) {
        guard realTime else { return waitForWake(language) }
        if let problem = startRealTime(language, greet: true, startedBy: "started on its screen") {
            log.add("Interpreter: real time couldn't start (\(problem.logText))")
            endNote = problem.screenNote
        }
    }

    // MARK: Can it start?

    /// The sentence for a missing ElevenLabs key, on the screen and spoken by voice.
    static let noElevenLabsKey = "The interpreter needs an ElevenLabs key. Add one in ReGlass's Keys."

    /// True when the ElevenLabs key is saved, false when it isn't, nil when the Keychain can't be read yet (the
    /// iPhone not unlocked since it restarted).
    private static var hasElevenLabsKey: Bool? {
        do {
            return try KeyStore.shared.read(.elevenLabs) != nil
        } catch {
            return nil
        }
    }

    /// What the interpreter can't work without, for its connector's row. Nil when it's all there.
    static func missingSetup() -> String? {
        if hasElevenLabsKey == false { return "Needs an ElevenLabs key." }
        if SpeechRecognition.choice != .elevenLabs { return "Needs ElevenLabs speech recognition." }
        return nil
    }

    /// Why the interpreter can't start now, in one plain sentence (for the screen, and for the voice to say). Nil
    /// when it can.
    static func blocker() -> String? {
        if hasElevenLabsKey == false { return noElevenLabsKey }
        if SpeechRecognition.choice != .elevenLabs {
            return "The interpreter needs ElevenLabs to understand other languages. Choose ElevenLabs in ReGlass's "
                + "speech recognition settings."
        }
        if SpeechRecognition.cloudStatus.keepsRecognitionOnIPhone {
            return "ElevenLabs can't understand speech for ReGlass right now, so the interpreter can't hear other languages."
        }
        if FollowUps.onACall { return "The interpreter can't run during a phone call." }
        return nil
    }

    // MARK: Starting

    /// `start_interpreter` ran in this voice turn: hand the turn over once Claude's reply has played.
    func requestFromVoice(_ language: InterpreterLanguage) {
        voiceRequest = (language, Date())
        log.add("Interpreter: \(language.name) asked for by voice")
    }

    /// The language `start_interpreter` asked for in the turn that's just been answered, if any.
    func takeVoiceRequest() -> InterpreterLanguage? {
        defer { voiceRequest = nil }
        guard let request = voiceRequest, Date().timeIntervalSince(request.at) < 90 else { return nil }
        return request.language
    }

    /// The screen's Start: the next "Hey Meta" begins the interpreter (for up to five minutes).
    func waitForWake(_ language: InterpreterLanguage) {
        guard !isRunning else { return }
        self.language = language
        lines = []
        endNote = nil
        status = .waitingForWake
        let until = Date().addingTimeInterval(Self.waitForWake)
        waitingUntil = until
        waitTimer?.cancel()
        waitTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.waitForWake))
            guard !Task.isCancelled, let self, self.status == .waitingForWake else { return }
            self.status = .off
            self.waitingUntil = nil
            self.endNote = "Stopped waiting for \u{201C}Hey Meta\u{201D}."
            self.log.add("Interpreter: stopped waiting for a wake word")
        }
        log.add("Interpreter: waiting for a wake word (\(language.name))")
    }

    /// Called as each voice turn opens. Forgets a voice request an earlier turn never got to (its reply was cut off),
    /// notes that a running session is being ended by this wake word, and returns the language to start with when
    /// the screen's Start is waiting for it.
    func takeWaitingStart() -> InterpreterLanguage? {
        voiceRequest = nil
        if isRunning { endedFromOutsideAt = Date() }
        // Real time: a wake word ends it at once, so two sessions never fight over audio. "Hey Meta, stop" then gets
        // the closing line in the new turn (`isStopAfterWake`); anything else is handled as a normal request.
        if let run = realTimeRun { stopRealTime(run, ending: "a wake word", closing: false, hard: true) }
        guard status == .waitingForWake, let language, let until = waitingUntil, Date() < until else { return nil }
        waitTimer?.cancel()
        waitingUntil = nil
        status = .starting
        return language
    }

    /// Stop on the screen: stops waiting, or ends the session after the line being translated (the voice says so).
    func stop() {
        switch status {
        case .off:
            return
        case .waitingForWake:
            waitTimer?.cancel()
            waitingUntil = nil
            status = .off
            log.add("Interpreter: stopped waiting for a wake word")
        default:
            if let run = realTimeRun {
                log.add("Interpreter: Stop tapped")
                stopRealTime(run, ending: "Stop on the screen", closing: true)
                return
            }
            guard !stopRequested else { return }
            stopRequested = true
            stopCurrentListen?()
            log.add("Interpreter: Stop tapped")
        }
    }

    /// Clears the last session's lines from the screen (they stay in Chats).
    func clear() {
        guard !isRunning else { return }
        lines = []
        endNote = nil
    }

    /// The interpreter ended a moment ago because its turn ended from outside, and the new turn's first words are a
    /// stop phrase: "Hey Meta, stop" as a fresh wake word. The caller says the closing line instead of asking Claude.
    func isStopAfterWake(_ transcript: String) -> Bool {
        guard let at = endedFromOutsideAt, Date().timeIntervalSince(at) < 30, Self.isStopPhrase(transcript) else {
            return false
        }
        endedFromOutsideAt = nil
        log.add("Interpreter: \u{201C}stop\u{201D} after a new wake word")
        return true
    }

    /// Recognises a direct voice request to start the interpreter ("interpret French", "interpreter French",
    /// "interpretation French", "live interpreter French", "translate French", "start interpreter") so ReGlass can start
    /// it right away without waiting on a Claude tool round-trip. Only while the Interpreter connector is on, as for
    /// Claude's `start_interpreter`.
    func matchedStartLanguage(in transcript: String) -> InterpreterLanguage? {
        let registry = ConnectorRegistry.shared
        guard let connector = registry.connector(id: InterpreterConnector.connectorID), registry.isOn(connector) else {
            return nil
        }
        guard !Self.isStopPhrase(transcript) else { return nil }
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 8 else { return nil }

        let triggerWords: Set<String> = [
            "interpret", "interpreter", "interpreting", "interpretation",
            "translate", "translator", "translating", "translation",
        ]
        guard words.contains(where: triggerWords.contains) else { return nil }
        // Don't hijack one-off translation questions like "how do you say hello in French" or "translate bonjour to English".
        let filler: Set<String> = [
            "ok", "okay", "hey", "meta", "reglass", "please", "can", "you", "could", "start", "begin", "open",
            "turn", "on", "the", "a", "an", "live", "mode", "in", "into", "from", "to", "between", "and", "with", "for",
            "me", "english",
            "interpret", "interpreter", "interpreting", "interpretation",
            "translate", "translator", "translating", "translation",
        ]
        let remaining = words.filter { !filler.contains($0) }
        if remaining.isEmpty {
            // Bare "start interpreter" / "interpreter": use the chosen language when interpreting, not bare "translate".
            let hasInterpret = words.contains { $0.hasPrefix("interpret") }
            return hasInterpret ? chosen : nil
        }
        guard remaining.count <= 2 else { return nil }
        let candidate = remaining.joined(separator: " ")
        if let matched = InterpreterLanguage.named(candidate) { return matched }
        for word in remaining {
            if let matched = InterpreterLanguage.named(word) { return matched }
        }
        return nil
    }

    // MARK: Taking turns

    private struct Counts {
        var lines = 0
        var english = 0
        var failed = 0
        var reopened = 0
    }

    /// Runs the interpreter in an open voice turn until it ends. `greet`: started from the screen, so the voice says it's
    /// on first (by voice, the reply already did).
    func run(language: InterpreterLanguage, greet: Bool, host: InterpreterHost) async {
        // Real time, started by voice: the real-time session takes over and this turn ends (real time opens its own
        // microphone; see `startRealTime`). If it can't start, the session takes turns in this voice turn instead.
        if realTime, !greet {
            guard let problem = startRealTime(language, greet: false, startedBy: "started by voice") else { return }
            log.add("Interpreter: real time couldn't start (\(problem.logText)); taking turns on the glasses' microphone")
        }
        generation += 1
        let me = generation
        self.language = language
        lines = []
        endNote = nil
        stopRequested = false
        endedFromOutsideAt = nil
        voiceRequest = nil
        status = .starting
        stopCurrentListen = host.stopListening
        let started = Date()
        isRealTimeSession = false
        partial = ""
        log.add("Interpreter: on, \(language.name) to English (\(greet ? "started on its screen" : "started by voice"))")
        translator.warmUp()

        let voice = Self.makeVoice()
        var recorder: ChatRecorder?
        var counts = Counts()
        var ending: String
        var lastSpeech = Date()
        var quickEmpties = 0
        var emptyMicAfterReopen = false

        if greet {
            status = .speaking
            host.setPhase(.speaking)
            let hello = ListeningChime.appended(to: voice.speak("Interpreting \(language.name). Go ahead."),
                                                when: { true })
            if !(await host.speak(hello)) { log.add("Interpreter: the greeting didn't play") }
        }

        while true {
            if host.isStopped() { ending = "the turn ended"; break }
            if stopRequested {
                await sayClosing(host, voice: voice, recorder: recorder)
                ending = "Stop on the screen"
                break
            }
            status = .listening
            host.setPhase(.listening)
            translator.warmUp()
            let listenStarted = Date()
            guard let heard = await host.listen(Self.listeningSettings(for: language)) else {
                ending = host.isStopped() ? "the turn ended" : "no recognizer"
                break
            }
            if host.isStopped() { ending = "the turn ended"; break }
            if stopRequested { continue }
            let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                if Date().timeIntervalSince(lastSpeech) >= Self.silenceLimit {
                    await sayClosing(host, voice: voice, recorder: recorder)
                    ending = "five minutes without speech"
                    break
                }
                // Guard against a listen that keeps ending at once (it should wait the whole window).
                quickEmpties = Date().timeIntervalSince(listenStarted) < 1 ? quickEmpties + 1 : 0
                if quickEmpties >= 3 { ending = "listening kept ending at once"; break }
                if heard.diagnostics.audioSeconds < 2 {
                    if emptyMicAfterReopen {
                        ending = "the turn ended"
                        break
                    }
                    // Hardly any audio in the whole window: the glasses' microphone stopped. Try reopening once; if
                    // the next window still gets no audio, the glasses closed the capture for good.
                    emptyMicAfterReopen = true
                    counts.reopened += 1
                    log.add("Interpreter: the microphone went quiet; reopening it")
                    guard await host.speak(Self.silence(seconds: 0.3)) else { ending = "the microphone couldn't be reopened"; break }
                } else {
                    emptyMicAfterReopen = false
                }
                continue
            }
            quickEmpties = 0
            emptyMicAfterReopen = false
            lastSpeech = Date()

            if Self.isStopPhrase(text) {
                await sayClosing(host, voice: voice, recorder: recorder)
                ending = "a stop phrase"
                break
            }
            if Self.isAlreadyEnglish(text, targetLanguage: language) {
                counts.english += 1
                continue
            }
            if recorder == nil {
                let chat = ChatRecorder(trigger: .unknown, startedAt: started)
                chat.setTitle("Interpreter · \(language.name)")
                recorder = chat
            }
            counts.lines += 1
            let worked = await translateAndSpeak(text, language: language, voice: voice, host: host,
                                                 recorder: recorder, number: counts.lines)
            if !worked.translated { counts.failed += 1 }
            if !worked.played {
                ending = host.isStopped() ? "the turn ended" : "a translation didn't play"
                break
            }
        }

        recorder?.end()
        if ending == "the turn ended" { endedFromOutsideAt = Date() }
        log.add("Interpreter: off (\(ending)) after \(Int(Date().timeIntervalSince(started).rounded())) s; "
                + "\(counts.lines) line\(counts.lines == 1 ? "" : "s")"
                + (counts.failed > 0 ? ", \(counts.failed) not translated" : "")
                + (counts.english > 0 ? ", \(counts.english) left alone as English" : "")
                + (counts.reopened > 0 ? ", microphone reopened \(counts.reopened)×" : ""))
        // A newer session (a fresh wake word started one while this one wound down) owns the shared state now.
        guard generation == me else { return }
        stopCurrentListen = nil
        stopRequested = false
        status = .off
        endNote = Self.endNote(ending, lines: counts.lines)
    }

    /// One utterance: shown and recorded, translated into English, spoken. `translated` is false when the
    /// translation failed (an apology was spoken instead); `played` is false when nothing could be played into the turn.
    private func translateAndSpeak(_ text: String, language: InterpreterLanguage, voice: ElevenLabsVoice,
                                   host: InterpreterHost, recorder: ChatRecorder?,
                                   number: Int) async -> (translated: Bool, played: Bool) {
        let line = Line(original: text)
        lines.append(line)
        recorder?.addOther(text)
        status = .translating
        host.setPhase(.thinking)
        await host.understood(text)
        guard !host.isStopped() else { return (false, false) }

        // The voice starts right away (its socket warms up while Claude translates) and speaks each sentence as it's
        // complete, with no beep after it so continuous translation isn't interrupted by chimes.
        let marks = StageMarks()
        let (sentences, sink) = AsyncStream<String>.makeStream()
        let audio = Self.timed(voice.speak(sentences), marks: marks) { [weak self] in
            Task { @MainActor in
                guard let self, self.status == .translating else { return }
                self.status = .speaking
                host.setPhase(.speaking)
            }
        }
        let playing = Task { @MainActor in await host.speak(audio) }

        var chunker = SentenceChunker()
        var translation = ""
        var failure: InterpreterTranslator.Failure?
        func say(_ piece: String) {
            let spoken = SpokenText.clean(piece)
            if !spoken.isEmpty { sink.yield(spoken) }
        }
        do {
            for try await piece in translator.translate(text, from: language, into: .english) {
                translation += piece
                update(line.id) { $0.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines) }
                for sentence in chunker.add(piece) { say(sentence) }
            }
            if let rest = chunker.flush() { say(rest) }
        } catch {
            failure = InterpreterTranslator.map(error)
        }
        let finalText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        // A failure mid-way keeps what was already said; with nothing said, a short apology.
        if finalText.isEmpty { sink.yield(Self.apology) }
        sink.finish()
        let played = await playing.value

        let translated = failure == nil && !finalText.isEmpty
        update(line.id) {
            $0.done = true
            $0.failed = !translated
            if $0.translation.isEmpty, !translated { $0.translation = Self.apology }
        }
        recorder?.addReply(finalText.isEmpty ? Self.apology : finalText)
        if let failure { log.add("Interpreter: line \(number) not translated (\(failure.kind))") }
        return (translated, played)
    }

    private func sayClosing(_ host: InterpreterHost, voice: ElevenLabsVoice, recorder: ChatRecorder?) async {
        status = .ending
        host.setPhase(.speaking)
        recorder?.addReply(Self.closingLine)
        _ = await host.speak(voice.speak(Self.closingLine))
    }

    func update(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[index])
    }

    // MARK: Rules

    /// Every listen: a follow-up window that waits `window` for someone to start, locked to the other person's
    /// language (no language auto-detection delay), with quicker sentence/pause cuts so speech is translated
    /// sentence by sentence rather than waiting for a whole paragraph.
    static func listeningSettings(for language: InterpreterLanguage) -> Transcriber.Settings {
        var settings = Transcriber.Settings(mode: .followUp(window: window))
        settings.language = language.code
        settings.followUpMinimumDB = minimumDB
        settings.endSilence = 0.65
        settings.endSilenceUnfinished = 0.95
        settings.maxDuration = window + 25
        // Cut as soon as a sentence ends after ~3.0 s of speech, or at 7.5 s at most.
        settings.sentenceCutAfter = 3.0
        settings.sentenceCutPause = 0.2
        settings.speechCap = 7.5
        return settings
    }

    /// True when the words are clearly in English (three words or more, at least 85 % English against the other
    /// language), so the wearer's own English remarks are never translated.
    static func isAlreadyEnglish(_ text: String, targetLanguage: InterpreterLanguage) -> Bool {
        guard targetLanguage != .english else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= 3 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, nlLanguage(targetLanguage)]
        recognizer.processString(text)
        let english = recognizer.languageHypotheses(withMaximum: 2)[.english] ?? 0
        return english >= 0.85
    }

    private static func nlLanguage(_ language: InterpreterLanguage) -> NLLanguage {
        switch language.code {
        case "zh": return .simplifiedChinese
        case "no": return .norwegian
        default: return NLLanguage(rawValue: language.code)
        }
    }

    /// The owner ending the interpreter: "stop", "stop interpreting", "Hey Meta, stop", "interpreter off", including
    /// when background speech (such as a video) was heard in the same segment right before the stop command, or when
    /// Scribe spelled "Hey Meta, stop" phonetically in the foreign language ("hey meta arrete").
    static func isStopPhrase(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
        let rawWords = folded
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !rawWords.isEmpty else { return false }

        let ignored: Set<String> = ["please", "now", "ok", "okay", "hey", "meta", "reglass"]
        let coreWords = rawWords.filter { !ignored.contains($0) }
        if stopPhrases.contains(coreWords.joined(separator: " ")) { return true }

        // Check if the utterance ends with or contains an explicit wake/interpreter stop command even when background
        // audio (e.g. a video playing in the room) was transcribed earlier in the same segment.
        let joinedRaw = rawWords.joined(separator: " ")
        for embedded in embeddedStopPhrases where joinedRaw.contains(embedded) {
            return true
        }
        if rawWords.count >= 2 {
            let tailCore = Array(rawWords.suffix(4)).filter { !ignored.contains($0) }.joined(separator: " ")
            if explicitStopTailPhrases.contains(tailCore) { return true }
        }
        return false
    }

    private static let stopPhrases: Set<String> = [
        "stop", "stopp", "stop it", "stopp it", "i said stop", "i said stopp", "said stop", "just stop",
        "stop interpreting", "stop interpreter", "stop the interpreter", "stop interpretation",
        "stop translating", "stop translation", "stop the translation", "stop the translator", "stop translator",
        "end interpreter", "end interpreting", "end the interpreter", "interpreter off", "interpreter stop",
        "turn off the interpreter", "turn off interpreter", "turn the interpreter off", "exit interpreter",
        "quit interpreter", "close the interpreter", "close interpreter", "stop listening",
        "arrete", "arretez", "arrete l'interprete", "arrete la traduction",
    ]

    private static let embeddedStopPhrases: [String] = [
        "hey meta stop", "ok meta stop", "okay meta stop",
        "hey meta stopp", "ok meta stopp", "ok stopp", "okay stopp", "i said stop", "i said stopp",
        "hey meta arrete", "ok meta arrete",
        "stop interpreting", "stop interpreter", "stop the interpreter", "stop translating", "stop translation",
        "interpreter off", "turn off the interpreter", "end interpreter", "quit interpreter",
    ]

    private static let explicitStopTailPhrases: Set<String> = [
        "stop", "stopp", "i said stop", "i said stopp",
        "stop interpreting", "stop interpreter", "stop the interpreter", "stop translating", "stop translation",
        "interpreter off", "end interpreter", "quit interpreter", "stop listening",
    ]

    static func endNote(_ ending: String, lines: Int) -> String {
        let count = lines == 0 ? "" : " after \(lines) line\(lines == 1 ? "" : "s")"
        switch ending {
        case "the turn ended": return "The interpreter ended on your glasses\(count)."
        case "five minutes without speech": return "The interpreter stopped after five quiet minutes."
        case "no recognizer": return "ReGlass couldn't listen, so the interpreter stopped."
        default: return "Interpreter off\(count)."
        }
    }

    // MARK: Audio

    /// `seconds` of silence at the reply rate (24 kHz).
    static func silence(seconds: Double) -> AsyncThrowingStream<[Int16], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Int16], Error>.makeStream()
        continuation.yield([Int16](repeating: 0, count: Int(seconds * 24_000)))
        continuation.finish()
        return stream
    }

    /// `audio` unchanged, noting when its first sound arrives. Cancelling the result cancels `audio`.
    nonisolated static func timed(_ audio: AsyncThrowingStream<[Int16], Error>, marks: StageMarks,
                                          firstAudio: @escaping @Sendable () -> Void) -> AsyncThrowingStream<[Int16], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Int16], Error>.makeStream()
        let task = Task {
            do {
                for try await chunk in audio {
                    if !chunk.isEmpty, marks.audio() { firstAudio() }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }
}

/// When one utterance's audio first arrived, from the moment its words were final.
final class StageMarks: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var firstAudio: Duration?

    /// True the first time.
    func audio() -> Bool {
        lock.withLock {
            guard firstAudio == nil else { return false }
            firstAudio = start.duration(to: .now)
            return true
        }
    }

    /// Seconds to the first audio, if it came.
    var firstAudioSeconds: Double? { lock.withLock { firstAudio.map(Self.seconds) } }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
