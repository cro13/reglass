import AVFoundation
import Foundation
import ReGlassAssistant
import ReGlassKit
import UIKit
import UserNotifications

/// The live interpreter in real time (a setting, on by default): ReGlass listens all the time, so it keeps hearing
/// while the voice talks, and each sentence is translated into English on the glasses as soon as it's said.
///
/// - **Microphones, in order** (`startRealTime`):
///   1. **The glasses' six microphones:** their own live-translation capture (`service 72` `InviteToJoin` → `s0`
///      `6102` header, `6100` audio, `6101` end; 16 kHz, 6 channels). Any open voice turn is closed first. The
///      channels go through `InterpreterSixChannelSelector` (a fixed mouth-null beamformer) and `InterpreterGain`.
///      While it's open, the background keep-alive plays on the iPhone's speaker, not the glasses.
///   2. **The iPhone's microphone**, if the glasses don't open theirs within 3 s: the audio session's recording hold
///      (play-and-record, mixable, never a Bluetooth headset microphone), when iOS's microphone permission is given.
///   3. **The glasses' assistant microphone**, if the iPhone's can't start (no permission, or ReGlass in the
///      background): the glasses are asked to listen, and one reply is held open in their new voice turn for the
///      whole session (`holdReply`), so their microphone keeps streaming. Its quiet audio goes through `InterpreterGain`.
/// - **Listening:** one ElevenLabs Scribe session for the whole conversation (`LiveTranscriber`), locked to the other
///   person's language, cut into sentence-sized segments (and live clauses of long sentences).
/// - **Each segment:** a stop phrase ends the session; English (`isAlreadyEnglish`) is left alone; the rest is
///   translated into English by `InterpreterTranslator` and spoken in the assistant's voice into the glasses: on their
///   live-translation player at 16 kbps while the six microphones stream, on their messaging player with the iPhone's
///   microphone (both with no voice turn open), or inside the held reply.
/// - **Pipelined:** the next segment is heard and translated while the one before plays. Playback is strictly in
///   order, one at a time.
/// - **The assistant's own voice** (the glasses' open-ear speakers, heard back by the microphones): a segment said
///   while it played (or just after) whose words are mostly what it said in the last 15 s is dropped
///   (`InterpreterEchoGuard`). Otherwise its words could come back as the other person's.
/// - **Stop:** "stop interpreting", Stop on the screen, five minutes without speech, a call or Siri, any wake word (it
///   ends at once, so the glasses' turn has the audio to itself; "Hey Meta, stop" then gets the closing line there),
///   ElevenLabs failing, the glasses ending their six microphones, the iPhone's microphone stopping, two lines in a
///   row that wouldn't play, or (held reply) the glasses not listening again. A tap on the glasses skips the
///   translation playing (not inside a held reply).
/// - Music stays dipped for the whole session: switching the dip needs a session restart, which would stop the
///   microphone.
///
/// The activity log gets counts, languages and timings only, never words: which microphone, events, and a summary.
@MainActor
final class InterpreterRealTimeRun {
    struct Counts {
        var lines = 0
        var echo = 0
        var english = 0
        var failed = 0
        var unplayed = 0
        var tapped = 0
    }

    /// An utterance still being spoken across live `.clause` cuts, so continuation clauses grow the current sentence
    /// card on screen and pass the immediately preceding clause + translation as context to Claude.
    struct ActiveUtterance {
        var lineID: UUID
        var number: Int
        var cardSourceText: String
        var lastJob: InterpreterRealTimeJob
    }

    let language: InterpreterLanguage
    let started = Date()
    let generation: Int
    let microphone = InterpreterMicrophone()
    let live: LiveTranscriber
    let voice: ElevenLabsVoice
    var recorder: ChatRecorder?
    var echo = InterpreterEchoGuard()
    var counts = Counts()
    /// The last speech, or the end of the voice's last line: five quiet minutes from here end the session.
    var lastSpeech = Date()
    var stopping = false
    /// Stopping: translations not yet playing are dropped.
    var dropQueued = false
    /// A hard stop: the held reply ends now, mid-line.
    var cutNow = false
    var events: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var playTail: Task<Void, Never>?
    var playTasks: [Task<Void, Never>] = []
    var jobs: [InterpreterRealTimeJob] = []
    /// The line the voice is saying now.
    var current: InterpreterRealTimeJob?
    var activeUtterance: ActiveUtterance?
    /// Listening with the glasses' assistant microphone on an open voice turn, for the whole session (the six
    /// microphones and the iPhone's didn't start). See `holdReply`.
    var glassesMode = false
    /// The open voice turn the glasses' microphone streams on. Nil with the six microphones or the iPhone's, and in
    /// glasses mode while ReGlass waits for the glasses to listen again (`reopening`).
    var turnHost: InterpreterHost?
    /// Glasses mode: the one reply held open on `turnHost` (it ends when the session or the turn does).
    var held: Task<Void, Never>?
    /// Glasses mode: the held reply should end once the line playing is done (stopping, or reopening).
    var finishHeld = false
    /// Glasses mode, stopping with a closing line: said at the end of the held reply.
    var closingText: String?
    /// Glasses mode: the glasses ended their microphone; ReGlass is asking them to listen again in a new turn.
    var reopening = false
    var reopens = 0
    /// Glasses mode: times the held reply ended by itself (a tap, a stall) and was started again.
    var replyRestarts = 0
    /// Glasses mode: the glasses' quiet microphone made loud enough to hear (`InterpreterGain`).
    var gain = InterpreterGain()
    /// The glasses' six microphones (`service 72` / `s0` `6100`) are the input.
    var liveTranslationMic = false
    var selector = InterpreterSixChannelSelector()
    var outwardGain = InterpreterGain(maxGainDB: InterpreterGain.outwardMicMaxGainDB)
    var micStartTask: Task<Void, Never>?
    private var turnDoneWaiters: [CheckedContinuation<Void, Never>] = []
    private var turnDone = false
    var pushFailuresInARow = 0
    var firstAudio: [Double] = []
    var interruption: NSObjectProtocol?

    init(language: InterpreterLanguage, generation: Int) {
        self.language = language
        self.generation = generation
        live = LiveTranscriber(languageCode: language.code)
        voice = InterpreterSession.makeVoice()
    }

    func waitTurnDone() async {
        if turnDone { return }
        await withCheckedContinuation { continuation in
            if turnDone {
                continuation.resume()
            } else {
                turnDoneWaiters.append(continuation)
            }
        }
    }

    /// Lets go of the current voice turn: whoever waits in `waitTurnDone` ends it.
    func finishTurnDone() {
        guard !turnDone else { return }
        turnDone = true
        let waiters = turnDoneWaiters
        turnDoneWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// A new voice turn is handed to the session (the glasses listened again): `waitTurnDone` waits for it.
    func adoptTurn(_ host: InterpreterHost) {
        turnHost = host
        turnDone = false
        reopening = false
        finishHeld = false
    }
}

/// One line's voice, read off as it's made so the held reply only starts it once it has sound (a held reply that
/// waits on a voice with nothing to send would stall, and the glasses end a reply after 2.5 s of nothing).
@MainActor
final class InterpreterJobAudio {
    var chunks: [[Int16]] = []
    var finished = false
    var failed = false
    var drain: Task<Void, Never>?

    init(_ audio: AsyncThrowingStream<[Int16], Error>) {
        drain = Task { @MainActor [weak self] in
            do {
                for try await chunk in audio where !chunk.isEmpty { self?.chunks.append(chunk) }
            } catch {
                self?.failed = true
            }
            self?.finished = true
        }
    }

    var hasSound: Bool { !chunks.isEmpty }

    func cancel() {
        drain?.cancel()
        finished = true
    }
}

/// One segment on its way: translated as soon as it's heard, played when its turn comes.
@MainActor
final class InterpreterRealTimeJob {
    let lineID: UUID
    let number: Int
    let text: String
    let previousJob: InterpreterRealTimeJob?
    let joinsPreviousCard: Bool
    let segment: LiveTranscriber.Segment
    let source: InterpreterLanguage
    let marks = StageMarks()
    var audio: AsyncThrowingStream<[Int16], Error>?
    /// `(clauseTranslation, cumulativeCardTranslation, failure)` once finished.
    var translation: Task<(clause: String, cumulative: String, failure: InterpreterTranslator.Failure?), Never>?
    var translating = true
    var startedPlayback = false
    /// Glasses mode: the voice's audio, read off ahead of its turn in the held reply.
    var buffered: InterpreterJobAudio?

    init(lineID: UUID, number: Int, text: String, previousJob: InterpreterRealTimeJob? = nil,
         joinsPreviousCard: Bool = false, segment: LiveTranscriber.Segment, source: InterpreterLanguage) {
        self.lineID = lineID
        self.number = number
        self.text = text
        self.previousJob = previousJob
        self.joinsPreviousCard = joinsPreviousCard
        self.segment = segment
        self.source = source
    }
}

extension InterpreterSession {
    /// Why real time didn't start.
    enum RealTimeProblem: Error {
        case busy
        case glasses
        case listener(LiveTranscriber.Failure)

        var logText: String {
            switch self {
            case .busy: return "a session is already on"
            case .glasses: return "the glasses' assistant isn't connected"
            case .listener(let failure): return "ElevenLabs: \(failure.kind)"
            }
        }

        /// One plain line for the screen.
        var screenNote: String {
            switch self {
            case .busy: return "The interpreter is already on."
            case .glasses: return "Connect your glasses to ReGlass first."
            case .listener(let failure): return failure.explanation
            }
        }
    }

    static let apology = "Sorry, I couldn't translate that."

    // MARK: Start

    /// True when the active real-time interpreter is streaming audio from the glasses' assistant microphone on an
    /// open voice turn (`.micAudio` and `.micAudioWhileBusy`).
    var feedsGlassesMic: Bool {
        guard let run = realTimeRun, !run.stopping else { return false }
        return run.turnHost != nil
    }

    /// True when the active real-time interpreter is streaming from the glasses' six microphones (`service 72` /
    /// `s0` `6100`).
    var usesLiveTranslationMic: Bool {
        guard let run = realTimeRun, !run.stopping else { return false }
        return run.liveTranslationMic
    }

    /// Feeds 16 kHz mono PCM from the glasses' assistant microphone (`.micAudio` and `.micAudioWhileBusy`), made
    /// louder, into `LiveTranscriber`.
    func appendGlassesMic(_ samples: [Int16]) {
        guard let run = realTimeRun, !run.stopping, run.turnHost != nil else { return }
        let louder = run.gain.process(samples)
        if !louder.isEmpty {
            run.live.append(louder)
        }
    }

    /// Feeds 6-channel 16 kHz PCM from the glasses' six microphones (`service 72` / `s0` `6100`) through
    /// `InterpreterSixChannelSelector` (mouth-null beamformer + own-voice detector) → `InterpreterGain` →
    /// `LiveTranscriber`.
    func appendLiveTranslationMic(_ channels: [[Int16]]) {
        guard let run = realTimeRun, !run.stopping, run.liveTranslationMic else { return }
        let (mono, isOwnVoice) = run.selector.beamform(channels)
        guard !mono.isEmpty else { return }
        let boosted = run.outwardGain.process(mono, freezeGain: isOwnVoice)
        if !boosted.isEmpty {
            run.live.append(boosted)
        }
    }

    /// The glasses ended their six-microphone stream (`6101` or a stop from the frame) while the session was still on.
    func liveTranslationMicEnded() {
        guard let run = realTimeRun, !run.stopping, run.liveTranslationMic else { return }
        log.add("Interpreter (real time): the glasses ended their six microphones after "
                + "\(Int(Date().timeIntervalSince(run.started).rounded())) s")
        stopRealTime(run, ending: "the glasses stopped live translation", closing: false,
                     note: "Your glasses stopped live translation.")
    }

    /// The glasses ended their microphone (`turnClosed`: closed the whole turn) while the session listened on it. A
    /// reply never brings it back in the same turn, so the held reply ends after the line playing, the turn is let
    /// go, and the glasses are asked to listen again in a new one (`reopen`).
    func glassesMicEnded(turnClosed: Bool) {
        guard let run = realTimeRun, !run.stopping, run.glassesMode, run.turnHost != nil, !run.reopening else { return }
        log.add("Interpreter (real time): the glasses \(turnClosed ? "closed the turn" : "ended their microphone") after "
                + "\(Int(Date().timeIntervalSince(run.started).rounded())) s; asking them to listen again")
        run.reopening = true
        run.finishHeld = true
    }

    /// True while the session waits for the glasses to open a new turn after `glassesMicEnded`: the next turn they
    /// open is handed to it (`adoptGlassesTurn`) rather than ending it, as a wake word would.
    var wantsGlassesTurn: Bool {
        guard let run = realTimeRun, !run.stopping else { return false }
        return run.glassesMode && run.reopening && run.turnHost == nil
    }

    /// The glasses listened again (a new turn) after their microphone ended: the session goes on in it until it ends.
    func adoptGlassesTurn(_ host: InterpreterHost) async {
        guard let run = realTimeRun, wantsGlassesTurn else { return }
        run.adoptTurn(host)
        log.add("Interpreter (real time): the glasses listen again (reopen \(run.reopens)); going on")
        holdReply(run)
        await run.waitTurnDone()
    }

    /// Starts the real-time interpreter now: opens the glasses' six microphones (`service 72` `InviteToJoin` → `s0`
    /// `6102`/`6100`), falling back to the iPhone's microphone, then to the glasses' assistant microphone in a held
    /// reply, only if the glasses don't open `6102`. Any voice turn open now is let go.
    func startRealTime(_ language: InterpreterLanguage, greet: Bool, startedBy: String) -> RealTimeProblem? {
        guard realTimeRun == nil, !isRunning else { return .busy }
        let assistant = AssistantController.shared
        guard assistant.linked, assistant.available else { return .glasses }
        generation += 1
        let run = InterpreterRealTimeRun(language: language, generation: generation)
        if let failure = run.live.start() {
            return .listener(failure)
        }

        // Release any voice turn immediately so the glasses can switch from their assistant to their live
        // translation when `InviteToJoin` arrives on `service 72`.
        run.liveTranslationMic = true
        run.finishTurnDone()
        assistant.interpreterDucking(true)
        // The keep-alive's silent loop moves to the iPhone's speaker: on the glasses' A2DP it took ~3/4 of the LE
        // link the six microphones need.
        assistant.keepAliveOnSpeakerForLiveTranslation(true)

        realTimeRun = run
        self.language = language
        lines = []
        endNote = nil
        partial = ""
        isRealTimeSession = true
        stopRequested = false
        endedFromOutsideAt = nil
        voiceRequest = nil
        status = .listening
        translator.warmUp()
        log.add("Interpreter: on in real time, \(language.name) to English (\(startedBy)); starting the glasses' "
                + "six microphones")

        run.events = Task { @MainActor [weak self] in
            for await event in run.live.events {
                guard let self else { return }
                self.handle(event, run)
            }
        }
        run.watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.realTimeRun === run, !run.stopping else { return }
                if run.current == nil, Date().timeIntervalSince(run.lastSpeech) >= Self.silenceLimit {
                    self.stopRealTime(run, ending: "five minutes without speech", closing: true)
                    return
                }
                if run.jobs.isEmpty { self.translator.warmUp() }
            }
        }
        run.interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                  object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .began else { return }
            MainActor.assumeIsolated {
                self?.stopRealTime(run, ending: "a call or Siri", closing: false, hard: true,
                                   note: "The interpreter stopped for a call or Siri.")
            }
        }
        run.micStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let opened = await assistant.startLiveTranslationMicrophone(sourceLanguage: language.code,
                                                                        targetLanguage: "en")
            guard self.realTimeRun === run, !run.stopping else { return }
            if opened {
                self.log.add("Interpreter (real time): listening with the glasses' six microphones")
                if greet {
                    self.enqueueLine("Interpreting \(language.name). Go ahead.", run)
                }
                return
            }
            // The glasses refused or timed out on service 72: the iPhone's microphone, else a voice turn on the
            // glasses (when ReGlass is in the background, iOS won't start the iPhone's).
            run.liveTranslationMic = false
            assistant.keepAliveOnSpeakerForLiveTranslation(false)
            self.log.add("Interpreter (real time): the glasses didn't open their six microphones; falling back")
            if AVAudioApplication.shared.recordPermission == .granted,
               assistant.beginInterpreterMicrophone() == nil {
                do {
                    let live = run.live
                    try run.microphone.start(onAudio: { samples in live.append(samples) }, onStop: { reason in
                        Task { @MainActor in InterpreterSession.shared.microphoneStopped(run, reason: reason) }
                    })
                    self.log.add("Interpreter (real time): listening with the iPhone's microphone")
                    if greet {
                        self.enqueueLine("Interpreting \(language.name). Go ahead.", run)
                    }
                    return
                } catch {
                    assistant.endInterpreterMicrophone()
                }
            }
            run.glassesMode = true
            run.reopening = true
            self.log.add("Interpreter (real time): listening with the glasses' assistant microphone")
            await self.reopen(run)
        }
        return nil
    }

    // MARK: Listening

    private func handle(_ event: LiveTranscriber.Event, _ run: InterpreterRealTimeRun) {
        guard realTimeRun === run, !run.stopping else { return }
        switch event {
        case .connected:
            break
        case .partial(let text):
            if partial != text { partial = text }
        case .segment(let segment):
            heard(segment, run)
        case .reconnecting(let kind):
            log.add("Interpreter (real time): the ElevenLabs connection dropped (\(kind)); reconnecting")
        case .failed(let failure):
            stopRealTime(run, ending: "ElevenLabs stopped (\(failure.kind))", closing: true, note: failure.explanation)
        }
    }

    private func heard(_ segment: LiveTranscriber.Segment, _ run: InterpreterRealTimeRun) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if !segment.continues, let active = run.activeUtterance {
                run.activeUtterance = nil
                let busy = run.jobs.contains { $0.lineID == active.lineID && $0.translating }
                if !busy { update(active.lineID) { $0.done = true } }
            }
            return
        }
        if !segment.continues { partial = "" }

        // Check stop commands before anything else, whether said alone or with background video audio.
        if Self.isStopPhrase(text) {
            run.activeUtterance = nil
            stopRealTime(run, ending: "a stop phrase", closing: true)
            return
        }
        if let active = run.activeUtterance, Self.isStopPhrase(Self.joinClauses(active.cardSourceText, text)) {
            run.activeUtterance = nil
            stopRealTime(run, ending: "a stop phrase", closing: true)
            return
        }

        if run.echo.isEcho(text, overlapped: segment.overlappedPlayback) {
            run.counts.echo += 1
            if !segment.continues { run.activeUtterance = nil }
            return
        }
        if Self.isAlreadyEnglish(text, targetLanguage: run.language) {
            run.counts.english += 1
            if !segment.continues { run.activeUtterance = nil }
            return
        }

        run.lastSpeech = Date()
        if run.recorder == nil {
            let chat = ChatRecorder(trigger: .unknown, startedAt: run.started)
            chat.setTitle("Interpreter · \(run.language.name) (real time)")
            run.recorder = chat
        }

        let source = run.language
        run.recorder?.addOther(text)

        let job: InterpreterRealTimeJob
        if segment.isContinuation, var active = run.activeUtterance {
            let prevEndedSentence = Transcriber.endsSentence(active.lastJob.text)
            let cardWords = active.cardSourceText.split(whereSeparator: \.isWhitespace).count
            let continuesSameCard = !prevEndedSentence && cardWords < 22

            if continuesSameCard {
                let combinedOriginal = Self.joinClauses(active.cardSourceText, text)
                update(active.lineID) {
                    $0.original = combinedOriginal
                    $0.done = false
                }
                job = InterpreterRealTimeJob(lineID: active.lineID, number: active.number, text: text,
                                             previousJob: active.lastJob, joinsPreviousCard: true,
                                             segment: segment, source: source)
                active.cardSourceText = combinedOriginal
            } else {
                let oldLineID = active.lineID
                let busy = run.jobs.contains { $0.lineID == oldLineID && $0.translating }
                if !busy { update(oldLineID) { $0.done = true } }
                run.counts.lines += 1
                let line = Line(original: text)
                lines.append(line)
                let number = run.counts.lines
                job = InterpreterRealTimeJob(lineID: line.id, number: number, text: text,
                                             previousJob: active.lastJob, joinsPreviousCard: false,
                                             segment: segment, source: source)
                active.lineID = line.id
                active.number = number
                active.cardSourceText = text
            }
            if segment.continues {
                active.lastJob = job
                run.activeUtterance = active
            } else {
                run.activeUtterance = nil
            }
        } else {
            if let old = run.activeUtterance {
                run.activeUtterance = nil
                let busy = run.jobs.contains { $0.lineID == old.lineID && $0.translating }
                if !busy { update(old.lineID) { $0.done = true } }
            }
            run.counts.lines += 1
            let line = Line(original: text)
            lines.append(line)
            let number = run.counts.lines
            job = InterpreterRealTimeJob(lineID: line.id, number: number, text: text, segment: segment, source: source)
            if segment.continues {
                run.activeUtterance = InterpreterRealTimeRun.ActiveUtterance(
                    lineID: line.id, number: number, cardSourceText: text, lastJob: job
                )
            }
        }
        run.jobs.append(job)
        translate(job, run)
        if run.glassesMode {
            // The held reply picks it up as soon as its voice has sound.
            if let audio = job.audio { job.buffered = InterpreterJobAudio(audio) }
        } else {
            enqueue(run) { [weak self] in await self?.play(job, run) }
        }
        refreshStatus(run)
    }

    // MARK: Translating

    /// Starts the translation into English now, streamed sentence by sentence into the assistant's voice (its audio
    /// waits in the stream until the line's turn to play). When `job` continues an earlier clause, it passes only the
    /// immediately preceding clause and its translation so Claude continues naturally without a growing prompt.
    private func translate(_ job: InterpreterRealTimeJob, _ run: InterpreterRealTimeRun) {
        let (sentences, sink) = AsyncStream<String>.makeStream()
        job.audio = Self.timed(run.voice.speak(sentences), marks: job.marks, firstAudio: {})
        let translator = self.translator
        job.translation = Task { @MainActor [weak self] in
            var prefixTranslation = ""
            var context: InterpreterTranslator.Context?
            if let previous = job.previousJob {
                let (priorClause, priorCumulative, _) = await previous.translation?.value ?? ("", "", nil)
                if job.joinsPreviousCard { prefixTranslation = priorCumulative }
                if !priorClause.isEmpty {
                    context = InterpreterTranslator.Context(source: previous.text, translation: priorClause)
                }
            }
            var chunker = SentenceChunker()
            var translation = ""
            var failure: InterpreterTranslator.Failure?
            func say(_ piece: String) {
                let spoken = SpokenText.clean(piece)
                if !spoken.isEmpty { sink.yield(spoken) }
            }
            do {
                for try await piece in translator.translate(job.text, from: job.source, into: .english,
                                                            context: context) {
                    translation += piece
                    let shown = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = prefixTranslation.isEmpty ? shown : Self.joinClauses(prefixTranslation, shown)
                    self?.update(job.lineID) { $0.translation = combined }
                    for sentence in chunker.add(piece) { say(sentence) }
                }
                if let rest = chunker.flush() { say(rest) }
            } catch {
                failure = InterpreterTranslator.map(error)
            }
            let final = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let cumulative = prefixTranslation.isEmpty ? final
                : (final.isEmpty ? prefixTranslation : Self.joinClauses(prefixTranslation, final))
            if cumulative.isEmpty, !Task.isCancelled { sink.yield(Self.apology) }
            sink.finish()
            job.translating = false
            guard let self, !Task.isCancelled else { return (final, cumulative, failure) }
            let translated = failure == nil && !final.isEmpty
            let moreComing = job.segment.continues && run.activeUtterance?.lineID == job.lineID
            let othersBusy = run.jobs.contains { $0 !== job && $0.lineID == job.lineID && $0.translating }
            self.update(job.lineID) {
                if !moreComing && !othersBusy { $0.done = true }
                if !translated && cumulative.isEmpty {
                    $0.failed = true
                    if $0.translation.isEmpty { $0.translation = Self.apology }
                } else {
                    $0.failed = false
                    $0.translation = cumulative
                }
            }
            let recorded = final.isEmpty ? (cumulative.isEmpty ? Self.apology : "") : final
            if !recorded.isEmpty {
                run.recorder?.addReply(recorded)
                run.echo.remember(recorded, id: job.lineID)
            }
            if !translated && cumulative.isEmpty { run.counts.failed += 1 }
            if let failure { self.log.add("Interpreter (real time): line \(job.number) not translated (\(failure.kind))") }
            self.refreshStatus(run)
            return (final, cumulative, failure)
        }
    }

    // MARK: Glasses mode: one reply held open

    /// How far the held reply's feeding runs ahead of real time. The glasses' link buffers 0.45 s more before it
    /// starts, so a line goes in about 0.7 s after its voice has sound.
    private static let heldLead = 0.25

    /// Glasses mode: keeps one reply open in the voice turn for the whole session. The glasses then never reach a
    /// follow-up window, where they end the microphone after 20 s with no request or at about the ninth; and their
    /// microphone streams all along (`micAudioWhileBusy` while a reply plays, with the voice below −77 dB in it).
    /// Between lines the reply carries silence; each translation goes in as soon as its voice has sound. A reply that
    /// ends by itself (a tap, a stall) is started again, up to six times.
    func holdReply(_ run: InterpreterRealTimeRun) {
        run.held = Task { @MainActor [weak self] in await self?.runHeldReply(run) }
    }

    private func runHeldReply(_ run: InterpreterRealTimeRun) async {
        while realTimeRun === run, !run.stopping, !run.finishHeld, let host = run.turnHost, !host.isStopped() {
            await host.understood("…")
            guard !run.stopping, !run.finishHeld, !host.isStopped() else { break }
            host.setPhase(.listening)
            let began = Date()
            let played = await host.speak(heldStream(run))
            if run.stopping || run.finishHeld || host.isStopped() { break }
            run.replyRestarts += 1
            log.add("Interpreter (real time): the held reply ended by itself after "
                    + "\(Int(Date().timeIntervalSince(began).rounded())) s (\(played ? "played" : "stopped")); "
                    + "starting another (\(run.replyRestarts))")
            if run.replyRestarts >= 6 {
                stopRealTime(run, ending: "the glasses kept ending the reply", closing: false,
                             note: "Your glasses kept stopping the interpreter, so it ended.")
                return
            }
        }
        guard realTimeRun === run, !run.stopping else { return }
        if run.reopening {
            await reopen(run)
            return
        }
        // The turn ended from outside: a new wake word (which ended the session already) or the link.
        endedFromOutsideAt = Date()
        stopRealTime(run, ending: "the turn ended", closing: false, hard: true)
    }

    /// The held reply's audio: silence paced in real time, with each line's voice in order as soon as it has sound.
    /// Ends once `finishHeld` is set and the line playing is done (with the closing line, when there is one).
    private func heldStream(_ run: InterpreterRealTimeRun) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            let feeder = Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                let clock = ContinuousClock()
                let start = clock.now
                var fed = 0.0
                func elapsed() -> Double { Self.seconds(start.duration(to: clock.now)) }
                func send(_ samples: [Int16]) async {
                    // Behind (the main actor was busy and the link padded silence): that gap isn't added back as delay.
                    fed = max(fed, elapsed())
                    continuation.yield(samples)
                    fed += Double(samples.count) / 24_000
                    let ahead = fed - elapsed() - Self.heldLead
                    if ahead > 0 { try? await Task.sleep(for: .milliseconds(Int(ahead * 1_000))) }
                }
                let tick = [Int16](repeating: 0, count: 2_400)   // 100 ms
                let gap = [Int16](repeating: 0, count: 960)      // 40 ms, while a voice is behind
                let breath = [Int16](repeating: 0, count: 1_440) // 60 ms between lines
                var closing: InterpreterJobAudio?

                while !Task.isCancelled, !run.cutNow {
                    if !run.finishHeld, let job = run.jobs.first(where: { !$0.startedPlayback }) {
                        guard let audio = job.buffered else {
                            job.startedPlayback = true
                            run.jobs.removeAll { $0 === job }
                            continue
                        }
                        if audio.hasSound || audio.finished {
                            job.startedPlayback = true
                            run.current = job
                            self.update(job.lineID) { $0.playing = true }
                            self.refreshStatus(run)
                            run.turnHost?.setPhase(.speaking)
                            while !Task.isCancelled, !run.cutNow {
                                if !audio.chunks.isEmpty {
                                    await send(audio.chunks.removeFirst())
                                } else if audio.finished {
                                    break
                                } else {
                                    await send(gap)
                                }
                            }
                            self.heldLineDone(job, run)
                            await send(breath)
                            continue
                        }
                        await send(gap)   // its voice is on the way
                        continue
                    } else if run.finishHeld {
                        if let text = run.closingText {
                            run.closingText = nil
                            run.echo.remember(text, id: nil)
                            closing = InterpreterJobAudio(run.voice.speak(text))
                        }
                        guard let said = closing else { break }
                        if !said.chunks.isEmpty {
                            await send(said.chunks.removeFirst())
                            continue
                        }
                        if said.finished { break }
                    }
                    await send(tick)
                }
                closing?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in feeder.cancel() }
        }
    }

    /// A line finished playing in the held reply.
    private func heldLineDone(_ job: InterpreterRealTimeJob, _ run: InterpreterRealTimeRun) {
        run.jobs.removeAll { $0 === job }
        run.current = nil
        run.lastSpeech = Date()
        if !run.jobs.contains(where: { $0.lineID == job.lineID }) {
            update(job.lineID) {
                $0.playing = false
                if run.activeUtterance?.lineID != job.lineID { $0.done = true }
            }
            run.echo.played(job.lineID)
        }
        if !run.cutNow { run.turnHost?.setPhase(.listening) }
        refreshStatus(run)
        if let firstAudio = job.marks.firstAudioSeconds { run.firstAudio.append(firstAudio) }
    }

    /// The glasses ended their microphone: the turn is let go and they're asked to listen again with no wake word
    /// (a turn-less reply that asks them to listen). Their new turn comes back through `adoptGlassesTurn`. If none
    /// comes, the voice says so and a notification offers to go on with the iPhone's microphone.
    private func reopen(_ run: InterpreterRealTimeRun) async {
        run.turnHost = nil
        run.reopens += 1
        run.finishTurnDone()   // `AssistantController.interpret` ends the old turn
        let asked = await AssistantController.shared.askGlassesToListen()
        let deadline = Date().addingTimeInterval(4)
        while asked, Date() < deadline, realTimeRun === run, !run.stopping, run.turnHost == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard realTimeRun === run, !run.stopping, run.turnHost == nil else { return }
        log.add("Interpreter (real time): the glasses didn't listen again (\(asked ? "no new turn" : "couldn't ask")); "
                + "offering the iPhone's microphone")
        let language = run.language
        stopRealTime(run, ending: "the glasses stopped listening", closing: true,
                     closingText: "Your glasses stopped listening. To keep going, tap the notification on your iPhone.",
                     note: "Your glasses stopped listening. Tap Start to go on with your iPhone's microphone.")
        postContinueNotification(language)
    }

    // MARK: Going on with the iPhone's microphone

    static let continueRequestID = "reglass.interpreter.continue"

    static func handlesNotification(_ requestID: String) -> Bool { requestID == continueRequestID }

    private func postContinueNotification(_ language: InterpreterLanguage) {
        continueLanguage = language
        let content = UNMutableNotificationContent()
        content.title = "Keep interpreting \(language.name)"
        content.body = "Tap to go on with your iPhone's microphone."
        let request = UNNotificationRequest(identifier: Self.continueRequestID, content: content, trigger: nil)
        Task { @MainActor [weak self] in
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                self?.log.add("Interpreter: the continue notification couldn't be shown")
            }
        }
    }

    /// The continue notification was tapped: ReGlass is coming on screen, where iOS lets it start the iPhone's
    /// microphone, which then keeps going when the phone is locked. (Real time starts as it always does: the glasses'
    /// six microphones first.)
    func continueOnIPhone() async {
        guard let language = continueLanguage else { return }
        continueLanguage = nil
        for _ in 0..<30 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let problem = startRealTime(language, greet: true, startedBy: "continued from the notification") {
            log.add("Interpreter: couldn't go on with the iPhone's microphone (\(problem.logText))")
            endNote = problem.screenNote
        }
    }

    // MARK: Playing

    /// Adds `work` to the playback queue: strictly in order, one at a time.
    private func enqueue(_ run: InterpreterRealTimeRun, _ work: @escaping @MainActor () async -> Void) {
        let previous = run.playTail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
        }
        run.playTail = task
        run.playTasks.removeAll { $0.isCancelled }
        run.playTasks.append(task)
    }

    private func play(_ firstJob: InterpreterRealTimeJob, _ run: InterpreterRealTimeRun) async {
        await run.micStartTask?.value
        guard !firstJob.startedPlayback else { return }
        guard !run.dropQueued, !Task.isCancelled, firstJob.audio != nil else {
            firstJob.startedPlayback = true
            firstJob.translation?.cancel()
            run.jobs.removeAll { $0 === firstJob }
            return
        }
        firstJob.startedPlayback = true
        var playedJobs: [InterpreterRealTimeJob] = [firstJob]
        run.current = firstJob
        update(firstJob.lineID) { $0.playing = true }
        refreshStatus(run)
        run.live.setPlaybackActive(true)

        let combinedAudio = AsyncThrowingStream<[Int16], Error> { [weak self] continuation in
            let feeder = Task { @MainActor [weak self] in
                var currentJob: InterpreterRealTimeJob? = firstJob
                let clock = ContinuousClock()
                var feedStart: ContinuousClock.Instant?
                var fedSamples = 0
                let breath = [Int16](repeating: 0, count: 1_440) // 60 ms between chained clauses

                while let job = currentJob, !Task.isCancelled, !run.dropQueued {
                    if let audio = job.audio {
                        do {
                            for try await chunk in audio where !chunk.isEmpty {
                                if feedStart == nil { feedStart = clock.now }
                                continuation.yield(chunk)
                                fedSamples += chunk.count
                                // Pace feeding ~0.55 s ahead of real-time 24 kHz playback so subsequent clauses that
                                // finish synthesizing while the voice speaks join this same uninterrupted stream.
                                if let start = feedStart {
                                    let playedDuration = Double(fedSamples) / 24_000.0
                                    let targetElapsed = playedDuration - 0.55
                                    if targetElapsed > 0 {
                                        let due = start.advanced(by: .milliseconds(Int(targetElapsed * 1_000)))
                                        try? await Task.sleep(until: due, clock: clock)
                                    }
                                }
                            }
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    // If another clause is already queued (or arrives while the 0.55 s buffered tail is still playing),
                    // chain it directly into this stream without closing 6000/6001.
                    var nextJob = run.jobs.first { !$0.startedPlayback }
                    if nextJob == nil, let start = feedStart {
                        let bufferedRemaining = (Double(fedSamples) / 24_000.0) - Self.seconds(start.duration(to: clock.now))
                        if bufferedRemaining > 0.18 {
                            let checks = min(6, Int((bufferedRemaining - 0.12) / 0.05))
                            for _ in 0..<max(0, checks) {
                                try? await Task.sleep(for: .milliseconds(50))
                                if Task.isCancelled || run.dropQueued { break }
                                nextJob = run.jobs.first { !$0.startedPlayback }
                                if nextJob != nil { break }
                            }
                        }
                    }

                    guard let next = nextJob, !Task.isCancelled, !run.dropQueued else {
                        currentJob = nil
                        break
                    }
                    next.startedPlayback = true
                    playedJobs.append(next)
                    if next.lineID != job.lineID {
                        self?.update(job.lineID) {
                            $0.playing = false
                            if run.activeUtterance?.lineID != job.lineID { $0.done = true }
                        }
                        run.echo.played(job.lineID)
                        self?.update(next.lineID) { $0.playing = true }
                    }
                    run.current = next
                    self?.refreshStatus(run)
                    continuation.yield(breath)
                    fedSamples += breath.count
                    currentJob = next
                }
                continuation.finish()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { feeder.cancel() }
            }
        }

        let outcome = await push(combinedAudio, run)
        run.live.setPlaybackActive(false)
        run.current = nil
        run.lastSpeech = Date()

        for job in playedJobs {
            run.jobs.removeAll { $0 === job }
            let nextSameLine = run.jobs.contains { $0.lineID == job.lineID }
            if !nextSameLine {
                update(job.lineID) {
                    $0.playing = false
                    if run.activeUtterance?.lineID != job.lineID { $0.done = true }
                }
                run.echo.played(job.lineID)
            }
            // The next line in the queue waits until this one's translation is done (a tap can cut its voice short).
            _ = await job.translation?.value
            if let firstAudio = job.marks.firstAudioSeconds { run.firstAudio.append(firstAudio) }
        }
        refreshStatus(run)
        count(outcome, run)
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func joinClauses(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if let last = a.last, let lead = b.first, isUnspacedCharacter(last) && isUnspacedCharacter(lead) {
            return a + b
        }
        return a + " " + b
    }

    private static func isUnspacedCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    /// The voice says `text` (the greeting) in its turn in the queue.
    private func enqueueLine(_ text: String, _ run: InterpreterRealTimeRun) {
        run.echo.remember(text, id: nil)
        enqueue(run) { [weak self] in
            guard let self, !run.dropQueued else { return }
            run.live.setPlaybackActive(true)
            let outcome = await self.push(run.voice.speak(text), run)
            run.live.setPlaybackActive(false)
            run.echo.played(nil)
            run.lastSpeech = Date()
            if case .failed(let why) = outcome { self.log.add("Interpreter (real time): the greeting didn't play (\(why))") }
        }
    }

    enum PushOutcome {
        case played
        case tapped
        case failed(String)
    }

    /// Plays `audio` on the glasses with no turn open: their live-translation player while the six microphones
    /// stream, their messaging player otherwise (the iPhone's microphone, and glasses mode's last words once its turn
    /// is gone; with a turn held, lines go into the held reply instead).
    private func push(_ audio: AsyncThrowingStream<[Int16], Error>, _ run: InterpreterRealTimeRun) async -> PushOutcome {
        let relay = InterpreterAudioRelay(audio)
        let deadline = Date().addingTimeInterval(8)
        while true {
            let stream = relay.stream()
            let (result, tapped) = await TapToStop.shared.announcing {
                await AssistantController.shared.pushInterpreterSpeech(stream)
            }
            if tapped { return .tapped }
            switch result {
            case .played?, .noAnswer?:
                return .played   // `noAnswer`: it most likely played, unconfirmed
            case .refused(let why)?:
                return .failed("refused, \(why)")
            case .unavailable(let why)? where relay.touched:
                return .failed(why)
            case nil, .unavailable?:
                guard Date() < deadline, !Task.isCancelled else {
                    if case .unavailable(let why)? = result { return .failed(why) }
                    return .failed("the glasses' assistant isn't available")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func count(_ outcome: PushOutcome, _ run: InterpreterRealTimeRun) {
        switch outcome {
        case .played:
            run.pushFailuresInARow = 0
        case .tapped:
            run.pushFailuresInARow = 0
            run.counts.tapped += 1
        case .failed(let why):
            run.counts.unplayed += 1
            run.pushFailuresInARow += 1
            log.add("Interpreter (real time): a line didn't play (\(why))")
            if run.pushFailuresInARow >= 2, !run.stopping {
                stopRealTime(run, ending: "the glasses didn't play two lines in a row", closing: false,
                             note: "ReGlass couldn't play on your glasses, so the interpreter stopped.")
            }
        }
    }

    private func refreshStatus(_ run: InterpreterRealTimeRun) {
        guard realTimeRun === run, !run.stopping else { return }
        let next: Status
        if run.current != nil {
            next = .speaking
        } else if run.jobs.contains(where: { $0.translating }) {
            next = .translating
        } else {
            next = .listening
        }
        if status != next { status = next }
    }

    // MARK: Stopping

    fileprivate func microphoneStopped(_ run: InterpreterRealTimeRun, reason: String) {
        log.add("Interpreter (real time): the iPhone's microphone stopped (\(reason))")
        stopRealTime(run, ending: "the microphone stopped", closing: true,
                     note: "Your iPhone's microphone stopped, so the interpreter did too.")
    }

    /// Ends the real-time session: the microphone goes off at once. `hard` (a wake word, a call): everything stops
    /// now. Otherwise the line being said finishes, lines still waiting are dropped, and with `closing` the voice says
    /// "Interpreter off."
    func stopRealTime(_ run: InterpreterRealTimeRun, ending: String, closing: Bool, hard: Bool = false,
                      closingText: String? = nil, note: String? = nil) {
        guard realTimeRun === run, !run.stopping else { return }
        run.stopping = true
        run.dropQueued = true
        run.micStartTask?.cancel()
        run.microphone.stop()
        run.live.stop()
        let assistant = AssistantController.shared
        let hadLiveTranslationMic = run.liveTranslationMic
        run.liveTranslationMic = false
        if hadLiveTranslationMic {
            Task { await assistant.stopLiveTranslationMicrophone() }
        }
        assistant.keepAliveOnSpeakerForLiveTranslation(false)
        // Music stays dipped until the last words have played.
        assistant.interpreterDucking(true)
        assistant.endInterpreterMicrophone()
        if let observer = run.interruption { NotificationCenter.default.removeObserver(observer) }
        run.interruption = nil
        run.watchdog?.cancel()
        run.events?.cancel()
        partial = ""
        status = .ending
        if hard {
            run.cutNow = true
            for task in run.playTasks { task.cancel() }
            for job in run.jobs {
                job.translation?.cancel()
                job.buffered?.cancel()
            }
        } else {
            // Translations that won't be played needn't finish.
            for job in run.jobs where job !== run.current {
                job.translation?.cancel()
                job.buffered?.cancel()
            }
        }
        let closingLine = closingText ?? Self.closingLine
        if closing, !hard { run.recorder?.addReply(closingLine) }
        // Glasses mode with a reply held: the line playing finishes, then the closing line, in that same reply.
        let held = run.turnHost != nil ? run.held : nil
        if held != nil {
            run.finishHeld = true
            if closing, !hard { run.closingText = closingLine }
        }
        let tail = run.playTail
        Task { @MainActor [weak self] in
            if let held {
                await held.value
            } else if !hard {
                await tail?.value
                if closing {
                    let outcome = await self?.push(run.voice.speak(closingLine), run)
                    if case .failed(let why)? = outcome {
                        self?.log.add("Interpreter (real time): the closing line didn't play (\(why))")
                    }
                }
            }
            self?.finishRealTime(run, ending: ending, note: note)
        }
    }

    private func finishRealTime(_ run: InterpreterRealTimeRun, ending: String, note: String?) {
        defer { run.finishTurnDone() }
        AssistantController.shared.interpreterDucking(false)
        AssistantController.shared.keepAliveOnSpeakerForLiveTranslation(false)
        run.recorder?.end()
        let totals = run.live.totals
        let counts = run.counts
        let sorted = run.firstAudio.sorted()
        let latency = sorted.isEmpty ? ""
            : "; first audio after the words were final: median \(Self.format(sorted[sorted.count / 2]))"
        // The session summary: the one log line per session with what happened, never words.
        log.add("Interpreter: off in real time (\(ending)) after \(Int(Date().timeIntervalSince(run.started).rounded())) s; "
                + "\(counts.lines) line\(counts.lines == 1 ? "" : "s")"
                + (counts.failed > 0 ? ", \(counts.failed) not translated" : "")
                + (counts.unplayed > 0 ? ", \(counts.unplayed) didn't play" : "")
                + (counts.tapped > 0 ? ", \(counts.tapped) skipped by a tap" : "")
                + (counts.english > 0 ? ", \(counts.english) left alone as English" : "")
                + (counts.echo > 0 ? ", \(counts.echo) dropped as ReGlass's own voice" : "")
                + (totals.reconnects > 0 ? ", ElevenLabs reconnected \(totals.reconnects)×" : "")
                + String(format: "; %.0f s of audio", totals.sentSeconds)
                + latency)
        guard realTimeRun === run else { return }
        realTimeRun = nil
        // A newer session (a wake word ended this one and started another) owns the shared state now.
        guard generation == run.generation else { return }
        status = .off
        partial = ""
        // Lines dropped when it stopped: no spinner left behind.
        for index in lines.indices where !lines[index].done || lines[index].playing {
            lines[index].done = true
            lines[index].playing = false
            if lines[index].translation.isEmpty { lines[index].failed = true }
        }
        endNote = note ?? (ending == "a wake word" ? "The interpreter stopped when you said \u{201C}Hey Meta\u{201D}."
                                                   : Self.endNote(ending, lines: counts.lines))
    }

    // MARK: Helpers

    static func format(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }
}

/// Hands one audio stream to the glasses' push and notes whether the push started reading it, so a push the glasses
/// turned away before reading anything can be tried again with the same audio.
final class InterpreterAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<[Int16], Error>.AsyncIterator
    private var started = false

    init(_ audio: AsyncThrowingStream<[Int16], Error>) {
        iterator = audio.makeAsyncIterator()
    }

    var touched: Bool { lock.withLock { started } }

    /// A fresh stream over what's left (one push at a time).
    func stream() -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream(unfolding: { [self] in
            lock.withLock { started = true }
            return try await next()
        })
    }

    private func next() async throws -> [Int16]? {
        try await iterator.next()
    }
}

/// The assistant's own voice, heard back by the microphones from the glasses' open-ear speakers. Without this, its
/// words could be heard as the other person's and translated again.
///
/// A segment said while it was playing (or just after) is its echo when its words are mostly its own from the last
/// 15 s: at least 70 % of its distinct words with three or more, all of them with one or two. Words are compared
/// without case or accents. Chinese, Japanese and Thai, written without spaces, are compared by character.
struct InterpreterEchoGuard {
    private struct Said {
        let id: UUID?
        let tokens: Set<String>
        let added: Date
        var ended: Date?
    }

    static let window: TimeInterval = 15
    private var said: [Said] = []

    /// What the voice is saying (or about to): a translation (`id` = its line) or a line of its own.
    mutating func remember(_ text: String, id: UUID?) {
        prune()
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return }
        said.append(Said(id: id, tokens: tokens, added: Date(), ended: nil))
    }

    /// It finished saying it: the 15 s start now.
    mutating func played(_ id: UUID?) {
        if let index = said.lastIndex(where: { $0.id == id && $0.ended == nil }) { said[index].ended = Date() }
    }

    mutating func isEcho(_ text: String, overlapped: Bool) -> Bool {
        prune()
        guard overlapped else { return false }
        let heard = Self.tokens(text)
        guard !heard.isEmpty else { return false }
        let recent = said.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
        let shared = heard.intersection(recent).count
        if heard.count >= 3 { return Double(shared) / Double(heard.count) >= 0.7 }
        return shared == heard.count
    }

    private mutating func prune() {
        let now = Date()
        // Never played (dropped or still waiting): kept a little longer, in case it's still to come.
        said.removeAll { ($0.ended ?? $0.added.addingTimeInterval(60)).addingTimeInterval(Self.window) < now }
    }

    static func tokens(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let unspaced = folded.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x0E00...0x0E7F).contains(scalar.value)
        }
        if unspaced { return Set(folded.filter { $0.isLetter }.map(String.init)) }
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
}
