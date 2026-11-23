import AVFoundation
import Foundation
import ReGlassAssistant
import ReGlassKit
import Speech
import SwiftUI
import UIKit

/// The assistant, joined up: the glasses' assistant link (ReGlassKit) on one side, ReGlassAssistant's transcriber, Claude
/// and voices on the other, Chats in between, and the audio session (keep-alive, ducking) around it.
///
/// The live link is injected with `connect(link:)` and dropped with `disconnect()`; nothing here reaches into
/// `GlassesConnection`. One wake word is one turn and one chat; a new wake mid-turn cancels the old turn.
///
/// The activity log gets states, sizes and timings only. Transcripts, replies, queries and keys never go there.
@MainActor
final class AssistantController: ObservableObject {
    static let shared = AssistantController()

    enum Phase: Equatable {
        case idle, listening, thinking, speaking
    }

    enum KeyTest: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    /// Talk to ReGlass: the request on screen and what's happened since.
    struct TypedTurn: Equatable {
        enum Status: Equatable {
            case thinking
            case speaking
            case done(String)
            case failed(String)
            case stopped
        }

        struct Action: Identifiable, Equatable {
            let id: String
            var title: String
            var detail: String?
            var status: ChatActionStatus
        }

        let id = UUID()
        let request: String
        var reply: [String] = []
        var actions: [Action] = []
        var status: Status = .thinking
        var voice: VoiceRoute?
        /// "Quick answer" or "Full answer", with its settings.
        var route: String?

        var isRunning: Bool { status == .thinking || status == .speaking }
    }

    /// A reply typed in a conversation in Chats: ReGlass's answer as it comes, until Chats has it.
    struct ChatReply: Equatable {
        let id = UUID()
        /// The conversation in Chats.
        let chat: UUID
        /// Read aloud into the glasses or headphones; otherwise text only.
        let readAloud: Bool
        var sentences: [String] = []
        var speaking = false
    }

    /// What was typed in the Reminders bar, and ReGlass's answer, shown above the bar.
    struct ReminderRequest: Equatable {
        enum Status: Equatable {
            case working
            /// Answered. `changed` when a reminder was set, cancelled or ticked off; otherwise ReGlass asked something
            /// (usually when), and the next line typed goes on with it.
            case done(changed: Bool)
            case failed(String)
        }

        let id = UUID()
        let request: String
        var reply: [String] = []
        var status: Status = .working
    }

    // MARK: Published state

    /// A link to the glasses' assistant service is connected.
    @Published private(set) var linked = false
    /// The glasses' assistant service is registered on that link.
    @Published private(set) var available = false
    @Published private(set) var phase: Phase = .idle
    /// "•••• abcd" per saved key.
    @Published private(set) var keyHints: [AssistantKey: String] = [:]
    @Published private(set) var keyTests: [AssistantKey: KeyTest] = [:]
    /// The chosen voice's Test in Voice and Speech (`testVoice`).
    @Published private(set) var voiceTest: KeyTest = .idle
    /// The Keychain won't open until the iPhone is unlocked once after a restart.
    @Published private(set) var keysLocked = false
    @Published private(set) var speechModel: SpeechModelStatus?
    @Published private(set) var typed: TypedTurn?
    @Published private(set) var chatReply: ChatReply?
    @Published private(set) var reminderRequest: ReminderRequest?
    var hasAnthropicKey: Bool { keyHints[.anthropic] != nil }

    // MARK: Parts

    private let log: ActivityLog
    private let keys = KeyStore.shared
    private let claude: ClaudeClient
    private let apple: AppleVoice
    /// The voice chosen in Settings → Assistant → Voice and speech (`VoiceProvider`), with Apple's standing by.
    private let replyVoice: ChosenVoice
    private let runner: TurnRunner
    /// The same, with no voice: replies typed in Chats while the iPhone's own speaker would say them.
    private let textRunner: TurnRunner
    private let audio: AssistantAudio
    private let typedPlayer = PCMPlayer()
    private let announcePlayer = PCMPlayer()
    private let chatPlayer = PCMPlayer()
    /// Voice turns' replies while the iPhone's audio goes to another Bluetooth speaker (`say`).
    private let turnPlayer = PCMPlayer()
    /// The voice's Test line (`testVoice`).
    private let testPlayer = PCMPlayer()
    private var voiceTestTask: Task<Void, Never>?
    private var voiceTestDucked = false

    private var link: (any GlassesAssistantLink)?
    private var linkEvents: Task<Void, Never>?
    private var voiceTurn: VoiceTurn?
    /// The last exchange, spoken or typed in Chats (what the owner said, what ReGlass said), in memory only: a new wake
    /// word or a new typed chat within `previousWindow` carries it as a note, and Claude decides whether the new
    /// request follows up on it.
    private var lastExchange: (request: String, reply: String, at: Date)?
    private static let previousWindow: TimeInterval = 5 * 60
    private var typedRun: TurnRun?
    private var typedTask: Task<Void, Never>?
    private var typedDucked = false
    private var chatRun: TurnRun?
    private var chatDucked = false
    private var reminderRun: TurnRun?
    /// The Reminders bar's last exchange when ReGlass asked something back, so the answer typed next goes on with it.
    private var reminderQuestion: (conversation: ClaudeConversation, at: Date)?
    /// The Claude conversations behind recent chats, exactly as sent and received (in memory only, newest last), so
    /// a reply typed in Chats replays the real thing. Older chats, and those from before this launch, go along as a
    /// note instead (`ChatRecorder.earlierNote`).
    private var claudeConversations: [(chat: UUID, conversation: ClaudeConversation)] = []
    private static let keptConversations = 12
    private var announcementTail: Task<AnnounceRoute, Never>?
    private var announceDucked = false
    /// The real-time interpreter's dip is on (`interpreterDucking`): one dip however many times it's asked for.
    private var interpreterDucked = false
    private var preparingSpeech = false
    private var spokeModelNotice = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let log = GlassesController.shared.log
        self.log = log
        AssistantLog.setSink { line in log.add(line) }
        claude = ClaudeClient()
        apple = AppleVoice()
        replyVoice = ChosenVoice(fallback: apple)
        runner = TurnRunner(claude: claude, voice: replyVoice, fallbackVoice: apple, tools: ConnectorRegistry.shared)
        textRunner = TurnRunner(claude: claude, voice: SilentVoice(), fallbackVoice: SilentVoice(),
                                tools: ConnectorRegistry.shared)
        audio = AssistantAudio(log: { log.add($0) })
        refreshKeys()
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshKeys()
                    self?.audio.restore()
                }
            })
        }
        if hasAnthropicKey { prepareSpeech() }
    }

    // MARK: The glasses' link

    /// Starts listening to the glasses' assistant service. Called by GlassesController with `connection.assistant`
    /// each time a live connection starts. Replaces any previous link.
    func connect(link newLink: any GlassesAssistantLink) {
        if let link, link === newLink { return }
        disconnect()
        link = newLink
        linked = true
        log.add("Assistant: glasses link connected")
        linkEvents = Task { [weak self] in
            for await event in newLink.events {
                guard let self else { return }
                self.handle(event, from: newLink)
            }
            self?.linkEnded(newLink)
        }
        updateKeepAlive()
        requestSpeechPermissionIfNeeded()
        if hasAnthropicKey { prepareSpeech() }
    }

    /// The live connection is going away. Stops any turn on it.
    func disconnect() {
        guard link != nil else { return }
        voiceTurn?.stop(byGlasses: true)
        linkEvents?.cancel()
        linkEvents = nil
        link = nil
        linked = false
        available = false
        log.add("Assistant: glasses link disconnected")
        updateKeepAlive()
    }

    private func linkEnded(_ ended: any GlassesAssistantLink) {
        guard let link, link === ended else { return }
        disconnect()
    }

    private func handle(_ event: AssistantEvent, from source: any GlassesAssistantLink) {
        guard let link, link === source else { return }
        switch event {
        case .availability(let up):
            if available != up { log.add("Assistant: glasses assistant service \(up ? "available" : "gone")") }
            available = up
            if !up { voiceTurn?.stop(byGlasses: true) }
        case .wake(let turn):
            startVoiceTurn(turn, on: link)
        case .micAudio(let turn, let samples):
            guard let current = voiceTurn, current.id == turn else { return }
            if InterpreterSession.shared.feedsGlassesMic {
                InterpreterSession.shared.appendGlassesMic(samples)
                return
            }
            current.transcriber.append(samples)
        case .micAudioWhileBusy(let turn, let samples):
            // While Claude works or the voice speaks: during continuous interpretation on the glasses' microphone, feed
            // the echo-cancelled stream straight into LiveTranscriber so nothing said while the voice speaks is lost.
            guard let current = voiceTurn, current.id == turn else { return }
            if InterpreterSession.shared.feedsGlassesMic {
                InterpreterSession.shared.appendGlassesMic(samples)
                return
            }
            if current.bargedIn {
                current.transcriber.append(samples)
            } else {
                current.spotter?.append(samples)
            }
        case .micEnded(let turn):
            guard let current = voiceTurn, current.id == turn else { return }
            if InterpreterSession.shared.feedsGlassesMic {
                InterpreterSession.shared.glassesMicEnded(turnClosed: false)
                return
            }
            current.transcriber.micEnded()
        case .turnClosed(let turn):
            guard let current = voiceTurn, current.id == turn else { return }
            log.add("Assistant: \(turn) closed by the glasses")
            if InterpreterSession.shared.feedsGlassesMic {
                InterpreterSession.shared.glassesMicEnded(turnClosed: true)
            }
            current.stop(byGlasses: true)
        case .liveTranslationMicAudio(let channels):
            InterpreterSession.shared.appendLiveTranslationMic(channels)
        case .liveTranslationMicState(let open):
            if !open {
                InterpreterSession.shared.liveTranslationMicEnded()
            }
        case .glassesAnnouncement(let kind):
            log.add("Assistant: the glasses announced on their own (\(kind))")
        case .glassesReport:
            break   // ReGlassKit logs what the glasses report on their own
        }
    }

    // MARK: Voice turns

    private func startVoiceTurn(_ id: AssistantTurnID, on link: any GlassesAssistantLink) {
        if let previous = voiceTurn {
            log.add("Assistant: a new wake word cancels \(previous.id)")
            previous.stop(byGlasses: true)   // the glasses close the old turn themselves
        }
        let turn = VoiceTurn(id: id, link: link)
        turn.cutIn = voiceTurn != nil   // tap to stop: "Hey Meta, stop" over a reply
        voiceTurn = turn
        claude.warmUp()
        turn.task = Task { [weak self] in
            await self?.runVoiceTurn(turn)
        }
    }

    /// One wake word: the request, Claude's spoken answer, then follow-ups without the wake word for as long as the
    /// wearer keeps going (each within `FollowUps.window` of the previous answer). Everything lands in one chat and
    /// one Claude conversation.
    private func runVoiceTurn(_ turn: VoiceTurn) async {
        let id = turn.id
        log.add("Assistant: \(id) opened by a wake word")
        phase = .listening
        var recorder: ChatRecorder?
        defer {
            recorder?.end()
            finishVoiceTurn(turn)
        }
        // Live interpreter, glasses' microphone: the glasses listened again after ending their microphone, as ReGlass
        // asked (`askGlassesToListen`). This turn carries the session on rather than ending it as a wake word does.
        if InterpreterSession.shared.wantsGlassesTurn {
            return await continueInterpreting(turn)
        }
        // Live interpreter (ReGlass/Interpreter/): started on its screen, this wake word begins it, without Claude.
        if let language = InterpreterSession.shared.takeWaitingStart() {
            return await interpret(turn, language: language, greet: true)
        }

        // 1. What the wearer says, transcribed on this iPhone.
        guard await turn.transcriber.start() else {
            if !turn.stopped { await speakNotice(modelNotice(), in: turn) }
            prepareSpeech()
            return
        }
        var conversation = ClaudeConversation()
        var followUps = 0
        /// The voice's last reply ended with a question: "OK" or "No" then answers it rather than closing the window.
        var askedAQuestion = false
        while true {
            let transcript = await listen(turn)
            turn.bargedIn = false
            guard !turn.stopped else { return }
            guard !transcript.isEmpty else {
                log.add(followUps == 0 ? "Assistant: \(id) heard nothing; ending it"
                        : "Assistant: \(id) follow-up window closed (nothing said)")
                return
            }
            // Live interpreter: "Hey Meta, stop" as a fresh wake word that just ended it gets its closing line.
            if followUps == 0, InterpreterSession.shared.isStopAfterWake(transcript) {
                return await speakNotice(InterpreterSession.closingLine, in: turn)
            }
            // Live interpreter: direct voice start ("Hey Meta, interpret French" / "interpretation French") starts
            // immediately without waiting on a Claude round-trip or tool call.
            if followUps == 0, let language = InterpreterSession.shared.matchedStartLanguage(in: transcript) {
                if let problem = InterpreterSession.blocker() {
                    return await speakNotice(problem, in: turn)
                }
                await turn.link.finalTranscript(id, transcript)
                guard !turn.stopped else { return }
                let chat = recorder ?? ChatRecorder(trigger: .unknown, startedAt: turn.wakeDate)
                recorder = chat
                chat.addUser(transcript)
                let greeting = "Interpreting \(language.name). Go ahead."
                chat.addReply(greeting)
                duck(turn)
                phase = .speaking
                do {
                    try await say(replyVoice.speak(greeting), in: turn, expectFollowUp: true, chime: { false })
                } catch {
                    log.add("Assistant: \(id) interpreter greeting stopped (\(Self.describe(error)))")
                    return
                }
                chat.end()
                return await interpret(turn, language: language, greet: false)
            }
            // Tap to stop's voice fallback: a closing phrase right after a wake word that cut into another turn
            // ("Hey Meta, stop" over the voice) also ends quietly, without asking Claude.
            if followUps > 0 || turn.cutIn, !askedAQuestion, let closing = FollowUps.closing(transcript) {
                log.add("Assistant: \(id) \(followUps > 0 ? "follow-up" : "request after cutting in") was a closing phrase")
                if closing == .thanks { await speakNotice("You're welcome.", in: turn) }
                return
            }
            await turn.link.finalTranscript(id, transcript)
            guard !turn.stopped else { return }

            // 2. Into Chats. The glasses don't say which wake word opened the turn, so the trigger is "on your
            // glasses". Follow-ups join the same chat.
            let chat = recorder ?? ChatRecorder(trigger: .unknown, startedAt: turn.wakeDate)
            recorder = chat
            chat.addUser(transcript)
            phase = .thinking

            // 3. Claude → voice → the glasses, music dipped while the voice speaks. The reply always asks the glasses to
            // keep listening; when no window should follow, the turn is closed right after instead.
            // The note only comes in a continuing conversation (its settings are pinned, so the note can't change the
            // route), after the request as it was said. Chats keeps the request alone.
            let notes = [conversation.isEmpty ? previousExchangeNote() : nil].compactMap { $0 }
            // "…see you at eight. ReGlass, also…" is two instructions (ReGlassAssistant's Addressing).
            let said = Addressing.parse(transcript)
            let request = notes.isEmpty ? said.text : said.text + "\n\n" + notes.joined(separator: " ")
            if said.parts.count > 1 { log.add("Assistant: \(id) request holds \(said.parts.count) instructions") }
            let run = runner.start(TurnRequest(transcript: request, conversation: conversation,
                                               context: turnContext(.glasses), instructions: said.parts.count))
            turn.run = run
            let exchange = ExchangeState()
            let canFollowUp = followUps < FollowUps.maxInARow
            // Barge-in (ReGlass/Assistant/BargeIn.swift): "Hey Meta" said while Claude works or the voice speaks cuts
            // the reply short and listens for the new request, in this chat.
            let gate = ReplyGate()
            let spotter = BargeInSpotter { [weak self] in
                MainActor.assumeIsolated { self?.bargeIn(turn, gate: gate) }
            }
            turn.spotter = spotter.start() ? spotter : nil
            let events = Task { @MainActor [weak self] () -> TurnOutcome? in
                var outcome: TurnOutcome?
                for await event in run.events {
                    chat.handle(event)
                    switch event {
                    case .sentence(let sentence):
                        spotter.replySays(sentence)
                    case .routed(let decision):
                        exchange.route = decision
                    case .toolStarted(_, let name) where FollowUps.mediaTools.contains(name):
                        exchange.usedMediaTool = true
                    case .firstAudio:
                        self?.duck(turn)
                        self?.phase = .speaking
                    case .finished(let done):
                        outcome = done
                    default:
                        break
                    }
                }
                return outcome
            }
            let wantsWindow: @Sendable () async -> Bool = { @MainActor in
                canFollowUp && !exchange.usedMediaTool && !FollowUps.isMediaCommand(transcript, route: exchange.route)
                    && !FollowUps.onACall
            }
            let audio = gate.wrap(run.audio)
            let chime: @Sendable () async -> Bool = { gate.wasCut ? false : await wantsWindow() }
            let speak = Task { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.say(audio, in: turn, expectFollowUp: true, chime: chime)
            }
            turn.speakTask = speak
            var spoke = true
            do {
                try await speak.value
            } catch {
                log.add("Assistant: \(id) reply stopped (\(Self.describe(error)))")
                run.cancel()
                spoke = false
            }
            if let spotter = turn.spotter {
                turn.spotter = nil
                logBargeInCheck(spotter.stop(), turn: id)
            }
            let bargedIn = gate.wasCut
            let outcome = await events.value
            chat.finishExchange(outcome)
            if let next = outcome?.conversation { remember(next, for: chat.conversationID) }
            if let said = outcome?.spokenText.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                lastExchange = (transcript, said, Date())
            }
            // Live interpreter: Claude called start_interpreter and its short reply has played; the turn is handed over.
            if spoke, !turn.stopped, let language = InterpreterSession.shared.takeVoiceRequest() {
                chat.end()
                return await interpret(turn, language: language, greet: false)
            }
            guard spoke, !turn.stopped else { return }
            guard bargedIn else {
                guard await wantsWindow() else { return }
                // 4. The follow-up window: a fresh transcriber on fresh audio (what was heard while the voice spoke
                // went to the barge-in check only). Music stays dipped while ReGlass listens.
                if let next = outcome?.conversation { conversation = next }
                askedAQuestion = outcome?.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ?? false
                followUps += 1
                turn.startFollowUp()
                phase = .listening
                log.add("Assistant: \(id) listening for a follow-up (\(followUps) of up to \(FollowUps.maxInARow))")
                guard await turn.transcriber.start() else { return }
                continue
            }
            // 4b. After a barge-in: the new request's transcriber has been listening since the wake phrase. No limit
            // on how many in a row: the wearer asked each time.
            if let next = outcome?.conversation { conversation = next }
            askedAQuestion = false
            followUps += 1
            phase = .listening
            log.add("Assistant: \(id) listening after a barge-in")
            let started: Bool
            if let pending = turn.bargeStarted { started = await pending.value } else { started = await turn.transcriber.start() }
            guard started else { return }
        }
    }

    /// Every wake word (and every new chat typed in Chats) starts a fresh conversation, but the owner may be following
    /// up ("and tomorrow?", "the cheaper one") or asking something new: the previous exchange from the last five
    /// minutes goes along, and Claude decides. Nil when there's none.
    private func previousExchangeNote() -> String? {
        guard let last = lastExchange else { return nil }
        let seconds = Date().timeIntervalSince(last.at)
        guard seconds < Self.previousWindow else { return nil }
        let when = seconds < 60 ? "under a minute ago" : seconds < 120 ? "a minute ago" : "\(Int(seconds / 60)) minutes ago"
        return "<context>The previous exchange, \(when), before this request: the owner said \u{201C}\(last.request)\u{201D} "
            + "and ReGlass answered \u{201C}\(last.reply)\u{201D} The new request may follow up on it or be about something "
            + "else entirely; decide from the words.</context>"
    }

    /// Runs the turn's current transcriber to its end and returns the request ("" when nothing was said).
    private func listen(_ turn: VoiceTurn) async -> String {
        let transcriber = turn.transcriber
        var transcript = ""
        for await event in transcriber.events {
            switch event {
            case .speechStarted:
                await turn.link.userSpeechStarted(turn.id)
            case .ended(let text, _):
                transcript = text
            }
        }
        return transcript
    }

    private func finishVoiceTurn(_ turn: VoiceTurn) {
        undock(turn)
        if !turn.closedByGlasses {
            let link = turn.link
            let id = turn.id
            Task { await link.endTurn(id) }
        }
        log.add("Assistant: \(turn.id) finished after \(String(format: "%.1f", Date().timeIntervalSince(turn.wakeDate))) s")
        if voiceTurn === turn {
            voiceTurn = nil
            phase = .idle
        }
    }

    /// A short line spoken into an open turn without asking Claude (e.g. speech recognition isn't ready).
    private func speakNotice(_ text: String, in turn: VoiceTurn) async {
        let speech = replyVoice.speak(text)
        duck(turn)
        let speak = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.say(speech, in: turn, expectFollowUp: false)
        }
        turn.speakTask = speak
        do {
            try await speak.value
        } catch {
            log.add("Assistant: notice stopped (\(Self.describe(error)))")
        }
        undock(turn)
    }

    private func modelNotice() -> String {
        switch speechModel {
        case .unsupported?:
            return "I can't understand speech on this iPhone yet. Open ReGlass to set it up."
        default:
            if spokeModelNotice { return "Speech recognition is still getting ready." }
            spokeModelNotice = true
            return "I'm still getting speech recognition ready on your iPhone. Please try again in a minute."
        }
    }

    private func duck(_ turn: VoiceTurn) {
        guard !turn.ducked else { return }
        turn.ducked = true
        audio.beginDucking()
    }

    private func undock(_ turn: VoiceTurn) {
        guard turn.ducked else { return }
        turn.ducked = false
        audio.endDucking()
    }

    // MARK: Where the voice speaks

    /// The assistant speaks `audio` into `turn`, then the listening chime when `chime` says so once it's done.
    /// Through the glasses' assistant link; or, while the iPhone's audio goes to another Bluetooth speaker (see
    /// `otherBluetoothOutput`), through the iPhone's audio route, with music dipped. The glasses wait meanwhile, then
    /// get a short silent reply, so they listen for a follow-up or close the turn as after any reply; the chime plays
    /// once they listen, about a second after the reply stops. Throws as `GlassesAssistantLink.speak`, or the voice's
    /// own error if it fails on the iPhone.
    private func say(_ audio: AsyncThrowingStream<[Int16], Error>, in turn: VoiceTurn, expectFollowUp: Bool,
                     chime: (@Sendable () async -> Bool)? = nil) async throws {
        guard let output = Self.otherBluetoothOutput else {
            let audio = chime.map { ListeningChime.appended(to: audio, when: $0) } ?? audio
            return try await turn.link.speak(turn.id, audio: audio, expectFollowUp: expectFollowUp)
        }
        log.add("Assistant: \(turn.id) the reply plays through the iPhone (its audio goes to \(output), not the glasses)")
        await turn.link.holdTurn(turn.id)
        let player = turnPlayer
        let seconds = try await player.play(audio, beforeFirstAudio: { [weak self] in await self?.duck(turn) })
        try Task.checkCancellation()
        log.add("Assistant: \(turn.id) the reply played on the iPhone (\(String(format: "%.1f", seconds)) s)")
        try await turn.link.speak(turn.id, audio: Self.samples(Self.handOver), expectFollowUp: expectFollowUp)
        if let chime, await chime() {
            try await player.play(Self.samples(ListeningChime.samples))
        }
    }

    /// The iPhone's audio goes to a Bluetooth speaker other than the glasses, or to CarPlay: that output's port type,
    /// for the log. Nil when it goes to the glasses, or off the radio. The keep-alive keeps an audio stream to that
    /// speaker running, and that stream can win the iPhone's Bluetooth radio over the glasses (the other device sets
    /// its own link's timing): the glasses then get too few packets a second for a reply, which cuts off after a few
    /// seconds. If the glasses' own Bluetooth audio isn't recognised by name, the reply goes to it from the iPhone and
    /// still plays in them.
    private static var otherBluetoothOutput: String? {
        let radio: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let other = outputs.first { $0.portType == .carAudio || (radio.contains($0.portType) && !isGlasses($0)) }
        return other?.portType.rawValue
    }

    /// The glasses' Bluetooth audio carries their advertised name ("RB Meta 00B2").
    private static func isGlasses(_ port: AVAudioSessionPortDescription) -> Bool {
        let name = port.portName.lowercased()
        return ["rb meta", "ray-ban", "oakley meta"].contains { name.hasPrefix($0) }
    }

    /// 200 ms of silence: the glasses' reply that ends one spoken on the iPhone.
    private static let handOver = [Int16](repeating: 0, count: 4_800)

    private static func samples(_ samples: [Int16]) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(samples)
            continuation.finish()
        }
    }

    // MARK: Barge-in (ReGlass/Assistant/BargeIn.swift)

    /// "Hey Meta" heard while Claude worked or the voice spoke: the reply stops with the listening chime, and the next
    /// request's transcriber starts now on what the microphone hears from here. Before any of the reply played, the
    /// request is dropped (Claude stops); during it, Claude's turn runs on unheard so its conversation stays whole.
    private func bargeIn(_ turn: VoiceTurn, gate: ReplyGate) {
        guard voiceTurn === turn, !turn.stopped, !turn.bargedIn, gate.cut(then: ListeningChime.samples) else { return }
        let thinking = phase == .thinking
        if thinking { turn.run?.cancel() }
        if let spotter = turn.spotter {
            turn.spotter = nil
            logBargeInCheck(spotter.stop(), turn: turn.id)
        }
        turn.startBargeIn()
        log.add("Assistant: \(turn.id) barge-in: the wake phrase was heard \(thinking ? "while Claude worked" : "over the reply"); "
                + "the reply stops and ReGlass listens")
    }

    /// How much microphone audio came while the turn wasn't listening, how loud, and whether the wake phrase was in
    /// it: the log's evidence for tuning barge-in (the voice's echo level, the glasses streaming at all).
    private func logBargeInCheck(_ summary: BargeInSpotter.Summary, turn: AssistantTurnID) {
        let level = summary.loudestDB.map { String(format: ", loudest %.0f dB", $0) } ?? ""
        log.add("Assistant: \(turn) barge-in check: \(String(format: "%.1f", summary.seconds)) s of microphone audio\(level), "
                + "\(summary.updates) recognition updates, wake phrase \(summary.heard ? "heard" : "not heard")")
    }

    // MARK: Live interpreter (ReGlass/Interpreter/)

    /// Hands an open voice turn to the live interpreter until it ends: it listens with its own transcriber settings
    /// (follow-up windows with no limit, locked to the other person's language, a lower loudness gate) and speaks into
    /// the same turn. Music stays dipped throughout. In real time, the session takes its own microphone and lets the
    /// turn go.
    private func interpret(_ turn: VoiceTurn, language: InterpreterLanguage, greet: Bool) async {
        duck(turn)
        await InterpreterSession.shared.run(language: language, greet: greet, host: interpreterHost(turn))
        await endInterpreterTurn(turn)
    }

    /// A turn the glasses opened when asked to listen again: the real-time session goes on in it until it ends.
    private func continueInterpreting(_ turn: VoiceTurn) async {
        duck(turn)
        log.add("Assistant: \(turn.id) the glasses listened again; the interpreter goes on in it")
        await InterpreterSession.shared.adoptGlassesTurn(interpreterHost(turn))
        await endInterpreterTurn(turn)
    }

    /// Real time is done with the turn (or never needed it): it ends now, so the glasses take turn-less audio again.
    private func endInterpreterTurn(_ turn: VoiceTurn) async {
        guard InterpreterSession.shared.isRealTimeSession, !InterpreterSession.shared.feedsGlassesMic else { return }
        if !turn.closedByGlasses { await turn.link.endTurn(turn.id) }
        turn.stop(byGlasses: true)
        if voiceTurn === turn {
            voiceTurn = nil
            phase = .idle
        }
    }

    /// The interpreter's way into an open turn: its own listening, and the voice's audio into the turn.
    private func interpreterHost(_ turn: VoiceTurn) -> InterpreterHost {
        InterpreterHost(
            listen: { [weak self] settings in
                turn.startFollowUp(settings)
                guard let self, await turn.transcriber.start() else { return nil }
                let text = await self.listen(turn)
                return InterpreterHeard(text: text, diagnostics: turn.transcriber.diagnostics)
            },
            stopListening: { turn.transcriber.cancel() },
            understood: { text in await turn.link.finalTranscript(turn.id, text) },
            speak: { [weak self] audio in
                let speak = Task { try await turn.link.speak(turn.id, audio: audio, expectFollowUp: true) }
                turn.speakTask = speak
                do {
                    try await speak.value
                    return true
                } catch {
                    self?.log.add("Assistant: \(turn.id) interpreter audio stopped (\(Self.describe(error)))")
                    return false
                }
            },
            setPhase: { [weak self] phase in self?.phase = phase },
            isStopped: { turn.stopped })
    }

    /// Real time on the glasses' microphone, after the glasses ended it: once no turn is open, a moment of silence
    /// goes to them shaped as a reply that expects an answer, so they listen again with no wake word (their new turn
    /// comes to `continueInterpreting`). False when that couldn't be asked: no link, or a turn still open after 3 s.
    func askGlassesToListen() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while voiceTurn != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let link, available, voiceTurn == nil else { return false }
        let result = await link.pushSpeechWithoutTurn(audio: InterpreterSession.silence(seconds: 0.3),
                                                      playback: .messaging, listenAfter: true)
        log.add("Assistant: asked the glasses to listen again for the interpreter (\(result))")
        switch result {
        case .played, .noAnswer: return true   // either way, their new turn (if any) is on its way
        case .refused, .unavailable: return false
        }
    }

    // MARK: Live interpreter, real time (ReGlass/Interpreter/InterpreterRealTime.swift)

    /// Requests outward live-translation capture with svc72 message 2. The s0 stream uses messages 6102, 6100 and
    /// 6101 for 16 kHz, 6-channel audio in mode `0x305`. Closes any open voice turn so the glasses can switch
    /// from the assistant (app 1) to live translation (app 6).
    func startLiveTranslationMicrophone(sourceLanguage: String, targetLanguage: String) async -> Bool {
        guard let link, available else { return false }
        if let turn = voiceTurn {
            if !turn.closedByGlasses {
                await turn.link.endTurn(turn.id)
                turn.stop(byGlasses: true)
            }
            voiceTurn = nil
            phase = .idle
        }
        return await link.startLiveTranslationMic(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    /// Stops the glasses' 6-channel outward live-translation microphone (`service 72` `TranslationStopRequest`).
    func stopLiveTranslationMicrophone() async {
        guard let link else { return }
        await link.stopLiveTranslationMic()
    }

    /// Plays `audio` on the glasses' live-translation (`field 19 = 4`) or messaging (`field 19 = 2`) player with no
    /// turn open. Nil when that can't happen now: no link, the glasses' assistant isn't available, or a voice turn is open.
    func pushInterpreterSpeech(_ audio: AsyncThrowingStream<[Int16], Error>) async -> AssistantPushResult? {
        guard let link, available else { return nil }
        if let turn = voiceTurn, InterpreterSession.shared.isRealTimeSession, !InterpreterSession.shared.feedsGlassesMic {
            if !turn.closedByGlasses {
                await turn.link.endTurn(turn.id)
                turn.stop(byGlasses: true)
            }
            voiceTurn = nil
            phase = .idle
        }
        guard voiceTurn == nil else { return nil }
        let playback: AssistantPlayback = InterpreterSession.shared.usesLiveTranslationMic ? .liveTranslation : .messaging
        return await link.pushSpeechWithoutTurn(audio: audio, playback: playback)
    }

    /// The iPhone's built-in microphone on (the audio session's recording hold), with music dipped, until
    /// `endInterpreterMicrophone()`. Nil when it's on, else a log-safe reason.
    func beginInterpreterMicrophone() -> String? { audio.beginRecording() }

    func endInterpreterMicrophone() { audio.endRecording() }

    /// Plays the background keep-alive's silent loop on the iPhone's speaker while the glasses' 6-channel microphone
    /// is open, so it doesn't take Bluetooth time from the microphone (see `AssistantAudio.keepAliveOnSpeaker`).
    func keepAliveOnSpeakerForLiveTranslation(_ on: Bool) { audio.keepAliveOnSpeaker(on) }

    /// Keeps music dipped while the real-time interpreter runs and its last words play after its microphone is off.
    /// Asking twice is one dip: the interpreter asks at its start and again when it stops, and lets go once when it's
    /// done. Counting each ask would leave music dipped after every session, at about half volume, until the app
    /// closed.
    func interpreterDucking(_ on: Bool) {
        guard interpreterDucked != on else { return }
        interpreterDucked = on
        if on { audio.beginDucking() } else { audio.endDucking() }
    }

    // MARK: Talk to ReGlass

    /// Answers a typed request in the assistant's voice through the iPhone's audio route, and records it in Chats.
    func ask(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        stopTyped()
        let recorder = ChatRecorder(trigger: .typed, startedAt: Date())
        recorder.addUser(request)
        typed = TypedTurn(request: request)
        claude.warmUp()
        log.add("Assistant: typed request (\(request.count) characters)")
        let said = Addressing.parse(request)
        let run = runner.start(TurnRequest(transcript: said.text, context: turnContext(.typed),
                                           instructions: said.parts.count))
        typedRun = run
        let player = typedPlayer
        typedTask = Task { [weak self] in
            let events = Task { @MainActor [weak self] () -> TurnOutcome? in
                var outcome: TurnOutcome?
                for await event in run.events {
                    recorder.handle(event)
                    self?.applyTyped(event)
                    if case .finished(let done) = event { outcome = done }
                }
                return outcome
            }
            do {
                try await player.play(run.audio, beforeFirstAudio: { [weak self] in
                    await self?.typedAudioStarting()
                })
            } catch {
                if !(error is CancellationError) { self?.log.add("Assistant: typed reply playback stopped (\(type(of: error)))") }
                run.cancel()
            }
            let outcome = await events.value
            self?.typedAudioEnded()
            recorder.finishExchange(outcome)
            recorder.end()
            if let next = outcome?.conversation { self?.remember(next, for: recorder.conversationID) }
        }
    }

    func stopTyped() {
        typedRun?.cancel()
        typedRun = nil
        typedPlayer.stop()
        if typed?.isRunning == true { typed?.status = .stopped }
    }

    /// Clears the finished request from the screen.
    func clearTyped() {
        guard typed?.isRunning != true else { return }
        typed = nil
    }

    private func typedAudioStarting() {
        if !typedDucked {
            typedDucked = true
            audio.beginDucking()
        }
        if typed?.isRunning == true { typed?.status = .speaking }
    }

    private func typedAudioEnded() {
        guard typedDucked else { return }
        typedDucked = false
        audio.endDucking()
    }

    private func applyTyped(_ event: TurnEvent) {
        guard var turn = typed else { return }
        switch event {
        case .routed(let decision):
            let kind = decision.route == .quick ? "Quick answer" : "Full answer"
            let thinking = decision.thinking == .disabled ? "no thinking" : "adaptive thinking"
            turn.route = "\(kind) · \(decision.effort.rawValue) effort, \(thinking)"
        case .searchStarted(let id, let query):
            turn.actions.append(.init(id: id, title: query.isEmpty ? "Searching the web" : "Searching the web for \u{201C}\(query)\u{201D}",
                                      detail: nil, status: .running))
        case .searchFinished(let id, let count):
            if let index = turn.actions.firstIndex(where: { $0.id == id }) {
                turn.actions[index].title = turn.actions[index].title.replacingOccurrences(of: "Searching", with: "Searched")
                turn.actions[index].detail = count == 0 ? "No results" : "\(count) result\(count == 1 ? "" : "s")"
                turn.actions[index].status = .done
            }
        case .searchFailed(let id, let reason):
            if let index = turn.actions.firstIndex(where: { $0.id == id }) {
                turn.actions[index].title = turn.actions[index].title.replacingOccurrences(of: "Searching", with: "Searched")
                turn.actions[index].detail = reason
                turn.actions[index].status = .failed
            }
        case .fetchStarted(let id, let url):
            turn.actions.append(.init(id: id, title: ChatRecorder.fetchTitle(url, done: false), detail: nil, status: .running))
        case .fetchFinished(let id, let url):
            if let index = turn.actions.firstIndex(where: { $0.id == id }) {
                turn.actions[index].title = url.isEmpty
                    ? turn.actions[index].title.replacingOccurrences(of: "Reading", with: "Read")
                    : ChatRecorder.fetchTitle(url, done: true)
                turn.actions[index].status = .done
            }
        case .fetchFailed(let id, let reason):
            if let index = turn.actions.firstIndex(where: { $0.id == id }) {
                turn.actions[index].title = turn.actions[index].title.replacingOccurrences(of: "Reading", with: "Read")
                turn.actions[index].detail = reason
                turn.actions[index].status = .failed
            }
        case .toolStarted(let id, let name):
            turn.actions.append(.init(id: id, title: ChatRecorder.toolTitle(name), detail: nil, status: .running))
        case .toolFinished(let id, let name, let result):
            if let index = turn.actions.firstIndex(where: { $0.id == id }) {
                let line = ChatRecorder.toolLine(name, result: result)
                turn.actions[index].title = line.title
                turn.actions[index].detail = line.detail
                turn.actions[index].status = result.isError ? .failed : .done
            }
        case .sentence(let sentence):
            turn.reply.append(sentence)
        case .firstAudio:
            if turn.isRunning { turn.status = .speaking }
        case .voice(let route):
            turn.voice = route
        case .finished(let outcome):
            for index in turn.actions.indices where turn.actions[index].status == .running {
                turn.actions[index].status = .cancelled
            }
            switch outcome.kind {
            case .answered, .empty, .cutShort:
                turn.status = .done(String(format: "Spoken in %.1f s", outcome.audioSeconds))
            case .refused:
                turn.status = .done("Claude declined to answer")
            case .failed(let error):
                turn.status = .failed(error.explanation)
            case .cancelled:
                turn.status = .stopped
            }
        }
        typed = turn
    }

    // MARK: Replying in Chats

    /// Goes on with conversation `chat` from a reply typed in Chats, for when talking out loud isn't an option. The
    /// answer shows in the conversation as it comes, and is read aloud only when the iPhone's audio goes to the
    /// glasses or headphones, never on its own speaker. When this launch still holds the chat's Claude conversation
    /// it's replayed as it went; otherwise what the chat says goes along as a note.
    ///
    /// One reply at a time: a new one in another chat stops the one running; in the same chat, Stop comes first.
    func reply(_ text: String, in chat: UUID) {
        answerTyped(text, in: chat, newChat: false)
    }

    /// Starts a new chat from a request typed in Chats, answered as `reply` answers. The previous exchange from the
    /// last five minutes goes along, as with a new wake word. Returns the chat's id, to open it; nil when there's
    /// nothing to send.
    func startChat(_ text: String) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let chat = ChatHistory.shared.beginConversation(trigger: .typed).id
        answerTyped(text, in: chat, newChat: true)
        return chat
    }

    private func answerTyped(_ text: String, in chat: UUID, newChat: Bool) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, chatReply?.chat != chat else { return }
        stopChatReply()
        let previous = claudeConversations.last { $0.chat == chat }?.conversation
        let earlier = newChat ? previousExchangeNote() : previous == nil ? ChatRecorder.earlierNote(chat) : nil
        guard let recorder = ChatRecorder(continuing: chat) else { return }
        recorder.addUser(words)
        let readAloud = Self.privateAudioRoute
        let state = ChatReply(chat: chat, readAloud: readAloud)
        chatReply = state
        claude.warmUp()
        let context = newChat ? "new chat" : previous == nil ? "chat as a note" : "same Claude conversation"
        log.add("Assistant: typed in Chats (\(words.count) characters, \(context), \(readAloud ? "read aloud" : "text only"))")
        let notes = [earlier].compactMap { $0 }
        let said = Addressing.parse(words)
        let request = notes.isEmpty ? said.text : said.text + "\n\n" + notes.joined(separator: " ")
        let run = (readAloud ? runner : textRunner).start(
            TurnRequest(transcript: request, conversation: previous ?? ClaudeConversation(),
                        context: turnContext(.chat(readAloud: readAloud)), instructions: said.parts.count))
        chatRun = run
        let player = chatPlayer
        Task { [weak self] in
            let events = Task { @MainActor [weak self] () -> TurnOutcome? in
                var outcome: TurnOutcome?
                for await event in run.events {
                    recorder.handle(event)
                    if case .sentence(let sentence) = event, self?.chatReply?.id == state.id {
                        self?.chatReply?.sentences.append(sentence)
                    }
                    if case .finished(let done) = event { outcome = done }
                }
                return outcome
            }
            do {
                if readAloud {
                    try await player.play(run.audio, beforeFirstAudio: { [weak self] in
                        await self?.chatAudioStarting(state.id)
                    })
                } else {
                    for try await _ in run.audio {}   // only the silence that bridges a search
                }
            } catch {
                if !(error is CancellationError) { self?.log.add("Assistant: Chats reply playback stopped (\(type(of: error)))") }
                run.cancel()
            }
            let outcome = await events.value
            self?.chatAudioEnded(state.id)
            recorder.finishExchange(outcome)
            recorder.end()
            if let next = outcome?.conversation { self?.remember(next, for: chat) }
            if let said = outcome?.spokenText.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
                self?.lastExchange = (words, said, Date())
            }
            if self?.chatReply?.id == state.id { self?.chatReply = nil }
        }
    }

    /// Stops the reply typed in Chats. What was already said stays in the chat.
    func stopChatReply() {
        chatRun?.cancel()
        chatRun = nil
        chatPlayer.stop()
    }

    /// The iPhone's audio goes where only the owner hears it: the glasses or other Bluetooth headphones, or wired
    /// ones. Not its own speaker, and not AirPlay or a car, where others hear it too.
    private static var privateAudioRoute: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let personal: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones]
        return !outputs.isEmpty && outputs.allSatisfy { personal.contains($0.portType) }
    }

    private func remember(_ conversation: ClaudeConversation, for chat: UUID) {
        claudeConversations.removeAll { $0.chat == chat }
        claudeConversations.append((chat, conversation))
        if claudeConversations.count > Self.keptConversations {
            claudeConversations.removeFirst(claudeConversations.count - Self.keptConversations)
        }
    }

    private func chatAudioStarting(_ id: UUID) {
        if !chatDucked {
            chatDucked = true
            audio.beginDucking()
        }
        if chatReply?.id == id { chatReply?.speaking = true }
    }

    /// The dip lifts when the reply that ends is the one on screen (or none is): one that was stopped for a reply in
    /// another chat leaves it to that one.
    private func chatAudioEnded(_ id: UUID) {
        guard chatDucked, chatReply == nil || chatReply?.id == id else { return }
        chatDucked = false
        audio.endDucking()
    }

    // MARK: Reminders bar

    /// Hands a line typed in the Reminders bar to Claude, which sets the reminder (or cancels, ticks off or lists them)
    /// with the same tools as "Hey Meta, remind me…": ReGlass doesn't read the times itself. The answer is text only,
    /// shown above the bar, and stays out of Chats. When ReGlass asked something back in the last five minutes (usually
    /// when), the new line goes on with that exchange. `category`: the chip selected on the page (Shopping open: "eggs
    /// and two lemons" goes on the Shopping list).
    func askAboutReminders(_ text: String, category: String? = nil) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        reminderRun?.cancel()
        let question = reminderQuestion.flatMap { Date().timeIntervalSince($0.at) < Self.previousWindow ? $0.conversation : nil }
        reminderQuestion = nil
        let state = ReminderRequest(request: words)
        reminderRequest = state
        claude.warmUp()
        log.add("Assistant: typed in Reminders (\(words.count) characters\(question == nil ? "" : ", answering ReGlass's question"))")
        let said = Addressing.parse(words)
        let run = textRunner.start(TurnRequest(transcript: said.text, conversation: question ?? ClaudeConversation(),
                                               context: turnContext(.reminders, openCategory: category),
                                               instructions: said.parts.count))
        reminderRun = run
        Task { [weak self] in
            let events = Task { @MainActor [weak self] () -> (outcome: TurnOutcome?, changed: Bool) in
                var outcome: TurnOutcome?
                var changed = false
                for await event in run.events {
                    switch event {
                    case .sentence(let sentence):
                        if self?.reminderRequest?.id == state.id { self?.reminderRequest?.reply.append(sentence) }
                    case .toolFinished(_, let name, let result):
                        // Only a real change carries a spoken reply; "which one?" and "all of them?" don't.
                        if !result.isError, result.spokenReply != nil, Self.changesReminders(name) { changed = true }
                    case .finished(let done):
                        outcome = done
                    default:
                        break
                    }
                }
                return (outcome, changed)
            }
            do {
                for try await _ in run.audio {}   // only the silence that bridges a search
            } catch {
                run.cancel()
            }
            let (outcome, changed) = await events.value
            guard let self, self.reminderRequest?.id == state.id else { return }
            self.reminderRun = nil
            switch outcome?.kind {
            case .failed(let error)?:
                self.reminderRequest?.status = .failed(error.explanation)
            case .cancelled?, nil:
                self.reminderRequest = nil
            default:
                self.reminderRequest?.status = .done(changed: changed)
                if !changed, let conversation = outcome?.conversation { self.reminderQuestion = (conversation, Date()) }
            }
        }
    }

    /// A line started elsewhere ("Remind me" on a note, "Change time" on a reminder) is about that, not an answer to
    /// whatever ReGlass asked last: forget the question, and the old answer with it.
    func startReminderAfresh() {
        reminderQuestion = nil
        clearReminderRequest()
    }

    /// Takes the Reminders bar's answer off the screen (not while ReGlass is still working on it).
    func clearReminderRequest() {
        guard reminderRequest?.status != .working else { return }
        reminderRequest = nil
    }

    /// The calls that set, move, snooze, cancel or tick off a reminder, or add to, tick off or sort a list: after one,
    /// the next line typed starts afresh.
    private static func changesReminders(_ tool: String) -> Bool {
        ["set_reminder", "change_reminder", "cancel_reminder", "snooze_reminder", "add_to_list", "tick_off_list_item",
         "move_to_category", "put_back"].contains(tool)
    }

    // MARK: Speaking without a wake word

    enum AnnounceRoute: Equatable {
        /// The glasses played it on their messaging player.
        case glasses
        /// It played through the iPhone's audio route (the glasses' assistant wasn't available or refused it).
        case phone
        /// It didn't play.
        case failed
    }

    /// Speaks `text` in the assistant's voice without a wake word: on the glasses' messaging player while their
    /// assistant is available (they play it with no turn open), otherwise, if `phoneFallback`, through the iPhone's
    /// audio route. For timers going off, reminders and anything else ReGlass says on its own.
    ///
    /// Announcements play one at a time, in call order. One waits (up to 30 s) while a voice turn is open, because the
    /// glasses take no turn-less audio then. Music dips while it plays. The text is never logged.
    /// `listenAfter`: the text wants the wearer's answer (decided by whoever wrote it), so the glasses are asked to
    /// listen right after it; their microphone then opens a voice turn as a wake word would.
    /// `glasses`: false skips the glasses' player and goes straight to the iPhone's audio route (and `phoneFallback`
    /// then decides nothing): for glasses known to be off the wearer's head, such as a reminder while they lie on a
    /// desk.
    @discardableResult
    func announce(_ text: String, phoneFallback: Bool = true, listenAfter: Bool = false,
                  glasses: Bool = true) async -> AnnounceRoute {
        let previous = announcementTail
        let task = Task { @MainActor [weak self] () -> AnnounceRoute in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return .failed }
            return await self.announceNow(text, phoneFallback: phoneFallback || !glasses, listenAfter: listenAfter,
                                          glasses: glasses)
        }
        announcementTail = task
        return await task.value
    }

    private func announceNow(_ text: String, phoneFallback: Bool, listenAfter: Bool, glasses: Bool) async -> AnnounceRoute {
        let deadline = Date().addingTimeInterval(30)
        while voiceTurn != nil, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if Task.isCancelled {
            log.add("Assistant: announcement stopped before it played")
            return .failed
        }
        audio.beginHold()
        defer { audio.endHold() }
        if glasses, let link, available, voiceTurn == nil {
            audio.beginDucking()
            // Tap to stop (ReGlass/TapToStop/): a tap on the glasses ends it, and then it isn't repeated on the iPhone.
            let speech = replyVoice.speak(text)
            let (result, tapped) = await TapToStop.shared.announcing {
                await link.pushSpeechWithoutTurn(audio: speech, playback: .messaging, listenAfter: listenAfter)
            }
            audio.endDucking()
            if Task.isCancelled {
                log.add("Assistant: announcement on the glasses stopped in the app")
                return .glasses
            }
            log.add("Assistant: announcement on the glasses: \(tapped ? "dismissed by tap" : "\(result)")")
            if tapped { return .glasses }
            switch result {
            case .played:
                return .glasses
            case .noAnswer:
                // It may well have played unconfirmed; repeating it on the iPhone could say it twice.
                return .glasses
            case .refused, .unavailable:
                break
            }
        }
        guard phoneFallback else { return .failed }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "ReGlass announcement") {
            MainActor.assumeIsolated {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                background = .invalid
            }
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            // Tap to stop (ReGlass/TapToStop/): a tap ends it early, which still counts as played.
            let player = announcePlayer
            let speech = replyVoice.speak(text)
            let starting: @Sendable () async -> Void = { [weak self] in await self?.announcementAudioStarting() }
            let seconds = try await TapToStop.shared.announcing(onPhone: {
                try await player.play(speech, beforeFirstAudio: starting)
            })
            endAnnouncementDuck()
            log.add("Assistant: announcement played on the iPhone (\(String(format: "%.1f", seconds)) s)")
            return .phone
        } catch {
            endAnnouncementDuck()
            if Task.isCancelled {
                log.add("Assistant: announcement on the iPhone stopped in the app")
                return .phone
            }
            log.add("Assistant: announcement didn't play (\(type(of: error)))")
            return .failed
        }
    }

    private func announcementAudioStarting() {
        guard !announceDucked else { return }
        announceDucked = true
        audio.beginDucking()
    }

    private func endAnnouncementDuck() {
        guard announceDucked else { return }
        announceDucked = false
        audio.endDucking()
    }

    // MARK: Tap to stop (ReGlass/TapToStop/)

    /// The voice turn whose reply is playing right now, if any.
    var speakingTurn: AssistantTurnID? {
        guard phase == .speaking, let turn = voiceTurn, !turn.stopped else { return nil }
        return turn.id
    }

    /// A tap on the glasses while the voice speaks `turn`'s reply: stops the reply, keeps the chat (with what was said),
    /// opens no follow-up window and lifts the music dip. The turn then ends as usual (turn message 11). False when
    /// that reply isn't playing.
    func stopReplyByTap(_ turn: AssistantTurnID) -> Bool {
        guard speakingTurn == turn, let current = voiceTurn else { return false }
        log.add("Assistant: \(turn) dismissed by tap")
        current.stop(byGlasses: false)
        return true
    }

    // MARK: Keys

    func refreshKeys() {
        var hints: [AssistantKey: String] = [:]
        var locked = false
        for key in AssistantKey.allCases {
            do {
                if let value = try keys.read(key) { hints[key] = KeyStore.hint(value) }
            } catch KeyStoreError.locked {
                locked = true
            } catch {
                log.add("Assistant: the Keychain couldn't be read")
            }
        }
        if hints != keyHints { keyHints = hints }
        if locked != keysLocked { keysLocked = locked }
        updateKeepAlive()
    }

    /// Saves a pasted key. Returns a plain reason when it can't.
    @discardableResult
    func saveKey(_ value: String, for key: AssistantKey) -> String? {
        do {
            try keys.save(value, for: key)
        } catch KeyStoreError.invalid {
            return "That doesn't look like a key. Paste the whole key."
        } catch KeyStoreError.locked {
            return "Unlock your iPhone, then try again."
        } catch {
            return "The Keychain couldn't save it. Try again."
        }
        keyTests[key] = .idle
        refreshKeys()
        if key == .anthropic {
            // The assistant is being set up, in the foreground: the moment to ask for speech recognition.
            requestSpeechPermissionIfNeeded()
            prepareSpeech()
        }
        return nil
    }

    func removeKey(_ key: AssistantKey) {
        try? keys.remove(key)
        keyTests[key] = .idle
        refreshKeys()
    }

    /// A cheap call with the saved key: Anthropic's model details (free), or a six-character ElevenLabs synthesis in
    /// the voice set in Voice and Speech. Without a voice ID, whether the ElevenLabs key can transcribe (free too).
    func testKey(_ key: AssistantKey) {
        guard keyTests[key] != .testing else { return }
        guard let value = try? keys.read(key) else {
            keyTests[key] = .failed(keysLocked ? "Unlock your iPhone, then try again." : "There's no key to test.")
            return
        }
        keyTests[key] = .testing
        Task { [weak self, claude] in
            let result: KeyTestResult
            switch key {
            case .anthropic:
                result = await claude.testKey(value)
            case .elevenLabs:
                result = VoiceSettings.elevenLabsVoiceID.isEmpty ? await Self.testTranscription()
                    : await ElevenLabsVoice(fallback: nil).testKey(value)
            }
            switch result {
            case .works(let message): self?.keyTests[key] = .passed(message)
            case .failed(let message): self?.keyTests[key] = .failed(message)
            }
        }
    }

    /// The ElevenLabs key's Test while no voice ID is set: can it transcribe? No audio is sent, so it costs nothing.
    private static func testTranscription() async -> KeyTestResult {
        switch await SpeechRecognition.checkKey() {
        case .works?: return .works("Works. ElevenLabs accepted the key for speech recognition.")
        case .keyCannotTranscribe?: return .failed("ElevenLabs didn't accept this key for speech to text.")
        case .termsNotAccepted?: return .failed(SpeechSettings.termsNotAccepted)
        case .quotaUsed?: return .failed("The ElevenLabs quota is used up.")
        case .noKey?: return .failed("There's no key to test.")
        case .unknown?, nil: return .failed("ReGlass couldn't reach ElevenLabs.")
        }
    }

    // MARK: Voice test (Settings → Assistant → Voice and speech)

    /// Says a short line in the chosen voice through the iPhone's audio route (the glasses, when they're its
    /// headphones), with music dipped, and shows what came of it in `voiceTest`. ElevenLabs spends the line's
    /// characters of quota.
    func testVoice() {
        guard voiceTest != .testing else { return }
        let provider = VoiceSettings.provider
        voiceTest = .testing
        log.add("Assistant: testing the \(provider.logName) voice")
        voiceTestTask = Task { [weak self] in
            let trial = await provider.trial(Self.voiceTestLine)
            guard let self, !Task.isCancelled else { return }
            switch trial {
            case .failed(let reason):
                self.voiceTest = .failed(reason)
            case .works(let samples, let message):
                self.voiceTest = .passed(message)
                self.audio.beginHold()
                let starting: @Sendable () async -> Void = { [weak self] in await self?.voiceTestAudioStarting() }
                do {
                    try await self.testPlayer.play(Self.samples(samples), beforeFirstAudio: starting)
                } catch {
                    if !(error is CancellationError) { self.log.add("Assistant: voice test didn't play (\(type(of: error)))") }
                }
                self.voiceTestAudioEnded()
                self.audio.endHold()
            }
        }
    }

    /// Stops a test and clears its line (the voice or its settings changed).
    func resetVoiceTest() {
        voiceTestTask?.cancel()
        voiceTestTask = nil
        testPlayer.stop()
        voiceTest = .idle
    }

    private static let voiceTestLine = "Hi, this is how ReGlass sounds."

    private func voiceTestAudioStarting() {
        guard !voiceTestDucked else { return }
        voiceTestDucked = true
        audio.beginDucking()
    }

    private func voiceTestAudioEnded() {
        guard voiceTestDucked else { return }
        voiceTestDucked = false
        audio.endDucking()
    }

    // MARK: Speech recognition

    /// Asks for speech recognition permission, only from the foreground and only once.
    func requestSpeechPermissionIfNeeded() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined,
              UIApplication.shared.applicationState == .active else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.log.add("Assistant: speech recognition permission \(status == .authorized ? "given" : "not given")")
            }
        }
    }

    /// Checks the on-device speech model and downloads it if it's missing.
    func prepareSpeech() {
        guard !preparingSpeech else { return }
        preparingSpeech = true
        Task { [weak self] in
            var status = await Transcriber.modelStatus()
            self?.speechModel = status
            if status == .notInstalled || status == .downloading {
                do {
                    try await Transcriber.installModel()
                } catch {
                    self?.log.add("Assistant: speech model download failed (\(type(of: error)))")
                }
                status = await Transcriber.modelStatus()
                self?.speechModel = status
            }
            self?.preparingSpeech = false
            if status == .ready { self?.spokeModelNotice = false }
        }
    }

    // MARK: Turn context

    /// The context note's facts for one turn: the categories, the list open on screen, and `extras` (short sentences
    /// about what's going on right now). Every turn's `ClaudeTurnContext` is made here, so a new kind of line is added
    /// in one place.
    private func turnContext(_ surface: ClaudeTurnContext.Surface, openCategory: String? = nil) -> ClaudeTurnContext {
        let extras = [ReminderSnooze.contextLine()].compactMap { $0 }
        return ClaudeTurnContext(surface: surface, categories: LibraryStore.shared.categoryNames(),
                                 openCategory: openCategory, extras: extras)
    }

    // MARK: Private

    private func updateKeepAlive() {
        audio.setKeepAlive(linked && hasAnthropicKey)
    }

    private static func describe(_ error: Error) -> String {
        if let kitError = error as? ReGlassError { return String(describing: kitError) }
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }
}

/// One wake word's turn.
@MainActor
private final class VoiceTurn {
    let id: AssistantTurnID
    let link: any GlassesAssistantLink
    let wakeDate = Date()
    /// The transcriber for the request being heard: the wake word's first, then one per follow-up window.
    private(set) var transcriber = Transcriber()
    var task: Task<Void, Never>?
    var run: TurnRun?
    var speakTask: Task<Void, Error>?
    var ducked = false
    /// Tap to stop's voice fallback: this turn's wake word cut into another turn, so a bare "stop" ends it quietly.
    var cutIn = false
    /// Listens for "Hey Meta" while Claude works or the voice speaks (ReGlass/Assistant/BargeIn.swift).
    var spotter: BargeInSpotter?
    /// The wake phrase was heard over this exchange: the microphone's audio goes to the next request's transcriber.
    var bargedIn = false
    /// That transcriber's start, awaited when the turn gets to listening.
    private(set) var bargeStarted: Task<Bool, Never>?
    /// The glasses ended it (closed, link gone, or a new wake): don't send endTurn.
    private(set) var closedByGlasses = false
    private(set) var stopped = false

    init(id: AssistantTurnID, link: any GlassesAssistantLink) {
        self.id = id
        self.link = link
    }

    /// A new follow-up window: a fresh transcriber that expects no wake word and may hear nothing. The live
    /// interpreter passes its own settings.
    func startFollowUp(_ settings: Transcriber.Settings = Transcriber.Settings(mode: .followUp(window: FollowUps.window))) {
        transcriber = Transcriber(settings: settings)
        run = nil
        speakTask = nil
    }

    /// Barge-in: the next request's transcriber, started now (as after a wake word: a leading wake phrase is dropped)
    /// while the cut reply finishes. The microphone's audio goes to it from here.
    func startBargeIn() {
        let next = Transcriber(settings: Transcriber.Settings(mode: .afterWake))
        transcriber = next
        bargedIn = true
        bargeStarted = Task { await next.start() }
    }

    /// Stops listening, Claude and the voice. The turn's task then records what happened and finishes.
    func stop(byGlasses: Bool) {
        closedByGlasses = closedByGlasses || byGlasses
        guard !stopped else { return }
        stopped = true
        _ = spotter?.stop()
        spotter = nil
        transcriber.cancel()
        run?.cancel()
        speakTask?.cancel()
    }
}
