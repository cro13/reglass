import Foundation

/// The glasses' assistant service (svc15) on the live connection: registers on every link, acknowledges the glasses'
/// envelopes, tracks turns, delivers the microphone, and speaks replies (see `AssistantReply.swift`).
///
/// Behaviour is the Audio glasses' path (IDNM protobuf profile), as these glasses answer it: what is sent, in what
/// order, which reply answers which wait, and the timeouts. The app decides when the wearer finished speaking and
/// what to say; this decides nothing about content and never logs it.
///
/// An actor: the link's reader (`receive`), the connection's events and the app's calls all reach it. Its state is
/// re-checked after every suspension, because any of them can change the turn meanwhile.
actor AssistantService: GlassesAssistantLink {
    // MARK: State

    /// One registration of the two svc15 channels on one link.
    struct Registration {
        let id: Int
        let mux: DataXMultiplexer
        /// The message channel (NetEvents, envelope acks) and the stream channel (reply audio).
        var m0: Int?
        var s0: Int?
        var registered = false
        let messageAnswered = OneShot<Void>()
        let streamAnswered = OneShot<Void>()
    }

    /// A StartSession's identity: field 1 (session) and field 4 (interaction, or the session when absent).
    struct StartKey: Hashable {
        let session: String
        let interaction: String
    }

    /// One turn the glasses opened.
    struct Turn {
        let id: AssistantTurnID
        /// StartSession field 1, or the microphone's session when the microphone opened the turn.
        let startSession: String
        /// StartSession field 4, or the session.
        let startInteraction: String
        /// The StartSessions this turn stands for: its own and any it kept (a repeat of one is ignored).
        var starts: Set<StartKey>
        /// The microphone header's session (field 6).
        var micSession: String?
        /// The microphone header's interaction: the id the turn's messages and reply carry once known.
        var micInteraction: String?
        var micStream = ""
        var micOpen = false
        /// Microphone audio goes to the app as the request until it's final;
        /// after that, until a follow-up listens, it goes as `micAudioWhileBusy`, for spotting a barge-in.
        var listening = true
        /// Samples that arrived while not listening since the request was final: logged when the turn listens
        /// again or ends, so the log shows whether the glasses stream their microphone while the voice speaks.
        var busySamples = 0
        var decoder: MicrophoneDecoder?
        var micChunks = 0
        var micFaults = 0
        var speechStartSent = false
        var finalSent = false
        var keepAlive: Task<Void, Never>?
        /// After a reply that expects a follow-up: the answered interaction and the new one.
        var completedInteraction: String?
        var followUpInteraction: String?
        let openedAt = ContinuousClock.now

        init(id: AssistantTurnID, session: String, startInteraction: String) {
            self.id = id
            self.startSession = session
            self.startInteraction = startInteraction
            self.starts = [StartKey(session: session, interaction: startInteraction)]
        }

        /// The interaction id this turn's messages carry.
        var interaction: String { followUpInteraction ?? micInteraction ?? startInteraction }

        func owns(session: String) -> Bool { session == startSession || session == micSession }
    }

    /// Why a turn ended.
    enum TurnEnd: CustomStringConvertible {
        case newWake, closedByGlasses, linkLost, channelsClosed, endedByApp, replyFinished

        /// The app is told with `.turnClosed`: everything except its own `endTurn` and a reply it just finished.
        var tellsApp: Bool {
            switch self {
            case .newWake, .closedByGlasses, .linkLost, .channelsClosed: return true
            case .endedByApp, .replyFinished: return false
            }
        }

        /// ReGlass closes the interaction on the glasses (turn message 11).
        var closesOnGlasses: Bool {
            switch self {
            case .endedByApp, .replyFinished: return true
            default: return false
            }
        }

        /// What a reply still streaming for the turn throws.
        var replyError: ReGlassError {
            switch self {
            case .linkLost, .channelsClosed: return .linkLost
            default: return .cancelled
            }
        }

        var description: String {
            switch self {
            case .newWake: return "a new wake"
            case .closedByGlasses: return "closed by the glasses"
            case .linkLost: return "link lost"
            case .channelsClosed: return "the glasses closed the assistant's channels"
            case .endedByApp: return "ended by ReGlass"
            case .replyFinished: return "reply finished"
            }
        }
    }

    /// One reply stream (a turn's, or a push's with no turn).
    struct Output {
        let id: Int
        let turn: AssistantTurnID?
        let interaction: String
        var headerSent = false
        var streamEnded = false
        var endedAt: ContinuousClock.Instant?
        var consumed = false
        /// Whether the accepted 6001 named this reply's interaction ("matched") or none ("none"). Log-safe.
        var consumedID: String?
        var glassesClosed = false
        var refusal: Int?
        var abort: ReGlassError?
        let settled = OneShot<PlaybackEnd>()
    }

    /// How a reply's wait for the glasses ended.
    enum PlaybackEnd: Sendable {
        /// 6001: the glasses played it out.
        case consumed
        /// The glasses closed the interaction after the stream ended.
        case closedByGlasses
        /// A DataX status on the assistant's channel (a push).
        case refused(Int)
        /// The turn or the link went away first.
        case interrupted
        /// Nothing within 10 s of the stream's end.
        case unconfirmed
    }

    // Events: one stream for the life of the connection.
    private nonisolated let stream: AsyncStream<AssistantEvent>
    nonisolated let eventSink: AsyncStream<AssistantEvent>.Continuation
    /// Microphone audio is decoded only once someone holds the events.
    nonisolated let hasConsumer = Locked(false)

    nonisolated var events: AsyncStream<AssistantEvent> {
        hasConsumer.withLock { $0 = true }
        return stream
    }

    var stopped = false
    /// Bumped on every link change, so work queued for an older link does nothing.
    var linkGeneration = 0
    var registration: Registration?
    var registrationCount = 0
    var bringUp: Task<Void, Never>?
    var reRegistration: Task<Void, Never>?
    var available = false
    var replyBitrate = AssistantMessages.defaultReplyBitrate
    /// Sends go out one after another in call order, whichever task makes them.
    var outboxTail: Task<Void, Error>?
    var segments = SegmentAssembler()

    var turn: Turn?
    var turnCount: UInt64 = 0
    /// Sessions recently ended: a late microphone header for one is ignored (a new StartSession reopens it).
    var closedSessions: [String] = []
    /// StartSessions of recently ended turns (only those with their own interaction id): an exact resend is ignored
    /// rather than opening a phantom turn.
    var endedStarts: [StartKey] = []

    var outputs: [Int: Output] = [:]
    var outputCount = 0
    /// The reply whose header went out last: what a 6001 answers.
    var playingOutput: Int?

    var unknownTypesLogged: Set<Int> = []
    var announcementsSeen: [String: ContinuousClock.Instant] = [:]
    /// A push with no turn open is running: meanwhile every svc15 message type the glasses send is logged.
    var pushRunning = false
    /// The connection's timers receive registration, turn-ended and timer alert events.
    nonisolated let timerHooks = Locked<TimerHooks?>(nil)

    // Outward 6-channel microphone capture state for live translation on svc72.
    weak var liveTranslationMux: DataXMultiplexer?
    var liveTranslationChannel: Int?
    var liveTranslationSessionID: String?
    var liveTranslationRequestID: String?
    var liveTranslationMicOpen = false
    /// Packets that came as the firmware's muted replacement frame: the 1st and every 25th get a TTSEnded to unmute.
    var liveTranslationMutedChunks = 0
    /// Packets that didn't parse: the first three are logged.
    var liveTranslationFaults = 0
    var liveTranslationDecoder: LiveTranslationMicDecoder?
    var liveTranslationStartWaiter: OneShot<Bool>?

    init() {
        let made = AsyncStream.makeStream(of: AssistantEvent.self)
        stream = made.stream
        eventSink = made.continuation
    }

    // MARK: The link (called by GlassesConnection)

    /// The token work for the current link must carry.
    func linkToken() -> Int { linkGeneration }

    /// The link is READY, trusted both ways, and svc100 named the saved glasses: register. Work for an older link,
    /// or a second call on the same one, does nothing. `replyBitrate` is svc100 field 12 when the glasses gave one.
    func linkReady(_ mux: DataXMultiplexer, token: Int, replyBitrate preferred: Int?) {
        guard !stopped, token == linkGeneration, registration == nil else { return }
        if let preferred, AssistantMessages.replyBitrates.contains(preferred) {
            replyBitrate = preferred
        } else {
            replyBitrate = AssistantMessages.defaultReplyBitrate
            if let preferred { log("the glasses asked for \(preferred) bps replies, not a rate they accept; using 32000") }
        }
        startRegistration(mux)
    }

    /// The link went away (or a new attempt began).
    func linkDown() async {
        linkGeneration += 1
        bringUp?.cancel()
        bringUp = nil
        reRegistration?.cancel()
        reRegistration = nil
        if turn != nil { await closeTurn(.linkLost) }
        if liveTranslationMicOpen {
            liveTranslationMicOpen = false
            emit(.liveTranslationMicState(false))
        }
        liveTranslationStartWaiter?.resolve(.success(false))
        liveTranslationStartWaiter = nil
        liveTranslationDecoder = nil
        liveTranslationSessionID = nil
        liveTranslationRequestID = nil
        liveTranslationChannel = nil
        liveTranslationMux = nil
        abortTurnlessOutputs(.linkLost)
        let had = registration != nil
        registration = nil
        segments = SegmentAssembler()
        setAvailable(false)
        if had { log("link gone; the assistant is off until the glasses reconnect") }
    }

    /// A DataX status the glasses answered on svc15. 0xC002 / 0xC010 on our channels means they closed them (a
    /// language switch restarts their assistant): register again 2.5 s later.
    func serviceStatus(channel: Int, status: Int) async {
        guard !stopped, let reg = registration else { return }
        let ours = [reg.m0, reg.s0].compactMap { $0.map { $0 & 0x7FFF } }
        guard ours.contains(channel & 0x7FFF) else { return }
        refuseTurnlessOutputs(status)
        guard status == 0xC002 || status == 0xC010 else {
            log(String(format: "the glasses answered status 0x%04lx on the assistant's channel", status))
            return
        }
        log(String(format: "the glasses closed the assistant's channels (0x%04lx); registering again in 2.5 s", status))
        if turn != nil { await closeTurn(.channelsClosed) }
        abortTurnlessOutputs(.linkLost)
        registration?.registered = false
        setAvailable(false)
        reRegistration?.cancel()
        let generation = linkGeneration
        reRegistration = Task {
            do { try await Task.sleep(for: .milliseconds(2_500)) } catch { return }
            await self.registerAgain(generation)
        }
    }

    /// The connection stopped for good: tell the app and end the events.
    func shutdown() async {
        guard !stopped else { return }
        await linkDown()
        stopped = true
        eventSink.finish()
    }

    // MARK: Registration

    private func startRegistration(_ mux: DataXMultiplexer) {
        registrationCount += 1
        let id = registrationCount
        registration = Registration(id: id, mux: mux)
        segments = SegmentAssembler()
        bringUp?.cancel()
        bringUp = Task { await self.register(id) }
    }

    private func registerAgain(_ generation: Int) async {
        guard !stopped, generation == linkGeneration, let reg = registration else { return }
        startRegistration(reg.mux)
    }

    /// m0 (1000 → 1001), s0 (5000 → 5001), each answer awaited up to 4 s and not required, then the seven
    /// resources 30 ms apart.
    private func register(_ id: Int) async {
        guard let mux = registration?.mux, registration?.id == id else { return }
        let client = AssistantMessages.newID()
        let session = AssistantMessages.sessionString()
        let began = ContinuousClock.now
        log("registering as the glasses' assistant")
        do {
            let m0 = await mux.openChannel(DataXService.assistant)
            guard registration?.id == id else { return }
            registration?.m0 = m0
            try await send(mux, m0, AssistantMessages.registration(session: session, client: client, endpoint: "\(client)-m0"),
                           type: AssistantMessageType.initMessageRequest, service: DataXService.assistant)
            let messageAnswered = await answered(registration?.messageAnswered)
            guard registration?.id == id, !Task.isCancelled else { return }
            if !messageAnswered { log("the glasses did not answer the message channel's registration") }

            let s0 = await mux.openChannel(DataXService.assistant)
            guard registration?.id == id else { return }
            registration?.s0 = s0
            try await send(mux, s0, AssistantMessages.registration(session: session, client: client, endpoint: "\(client)-s0"),
                           type: AssistantMessageType.initStreamRequest, service: DataXService.assistant)
            let streamAnswered = await answered(registration?.streamAnswered)
            guard registration?.id == id, !Task.isCancelled else { return }
            if !streamAnswered { log("the glasses did not answer the stream channel's registration") }

            for resource in AssistantMessages.resources() {
                guard registration?.id == id, !Task.isCancelled else { return }
                try await send(mux, m0, resource.payload, type: resource.type)
                try await Task.sleep(for: .milliseconds(30))
            }
            guard registration?.id == id else { return }
            registration?.registered = true
            setAvailable(true)
            log("registered as the glasses' assistant in \(milliseconds(began.duration(to: .now))) ms "
                + "(channels answered: message \(messageAnswered), stream \(streamAnswered); replies at \(replyBitrate) bps)")
            timerHooks.current?.registered()
        } catch {
            guard registration?.id == id, !(error is CancellationError) else { return }
            log("registration failed: \(ReGlassError.from(error))")
        }
    }

    private func answered(_ answer: OneShot<Void>?) async -> Bool {
        guard let answer else { return false }
        do {
            try await withTimeout(.seconds(4), "the assistant registration") { try await answer.value() }
            return true
        } catch {
            return false
        }
    }

    // MARK: What the glasses send

    /// Every svc15 message from the link's reader. Must return quickly: it runs inline with the reads.
    func receive(_ message: DataXMessage, from mux: DataXMultiplexer) async {
        guard !stopped, let reg = registration, reg.mux === mux else { return }
        let type = message.info.messageType
        let payload = message.payload
        if pushRunning,
           type != AssistantMessageType.streamAudio,
           type != AssistantMessageType.liveTranslationStreamAudio,
           type != 0 {
            log("push: the glasses sent type \(type) (\(payload.count) bytes)")
        }
        switch type {
        case AssistantMessageType.initMessageResponse:
            reg.messageAnswered.resolve(.success(()))
        case AssistantMessageType.initStreamResponse:
            reg.streamAnswered.resolve(.success(()))
        case AssistantMessageType.envelope:
            await envelope(payload)
        case AssistantMessageType.netEvent, AssistantMessageType.startInteraction, AssistantMessageType.startSession,
             AssistantMessageType.segmentHeader, AssistantMessageType.segmentBuffer:
            // Some glasses send these bare. Like envelopes, nothing is read before the message channel exists.
            guard reg.m0 != nil else { return }
            await inner(type, payload)
        case AssistantMessageType.streamHeader:
            await microphoneHeader(payload)
        case AssistantMessageType.streamAudio:
            microphoneChunk(payload)
        case AssistantMessageType.streamEnd:
            microphoneEnded()
        case AssistantMessageType.liveTranslationStreamHeader:
            await liveTranslationHeader(payload)
        case AssistantMessageType.liveTranslationStreamAudio:
            await liveTranslationChunk(payload)
        case AssistantMessageType.liveTranslationStreamEnd:
            liveTranslationEnded()
        case AssistantMessageType.streamStatus:
            if let status = replyStatus(payload) {
                log("the glasses decoded \(status.pcmBytes) PCM bytes of a \(status.milliseconds) ms reply")
            }
        case AssistantMessageType.streamConsumed:
            playbackConsumed(payload)
        case AssistantMessageType.runningLocale:
            log("the glasses' assistant language arrived (\(payload.count) bytes)")
        case AssistantMessageType.activeDeviceStateRequest:
            await activePhoneAsked()   // GlassesRequests.swift
        default:
            guard !AssistantMessageType.ignored.contains(type) else { return }
            if unknownTypesLogged.insert(type).inserted { log("message type \(type) from the glasses (\(payload.count) bytes)") }
            glassesAsked(kind: "assistant message \(type)", payload: payload, isRequestType: false)
        }
    }

    /// 9000: acknowledge first (unacknowledged, the glasses resend for minutes), then handle what it carries.
    private func envelope(_ payload: [UInt8]) async {
        guard let reg = registration, let m0 = reg.m0 else { return }
        let envelope: AssistantEnvelope
        do { envelope = try AssistantEnvelope.decode(payload) } catch {
            log("an unreadable envelope (\(payload.count) bytes)")
            return
        }
        if let seq = envelope.seq {
            guard seq >= 0 else { return log("an envelope with a negative sequence; not acknowledged") }
            do {
                try await send(reg.mux, m0, AssistantMessages.envelopeAck(seq), type: AssistantMessageType.envelopeAck)
            } catch {
                return log("an envelope acknowledgement failed")
            }
        }
        await inner(envelope.innerType, envelope.payload)
    }

    /// A message from an envelope, or sent bare.
    private func inner(_ type: Int, _ payload: [UInt8]) async {
        switch type {
        case AssistantMessageType.startSession:
            guard let start = try? StartSession.decode(payload) else {
                return log("a StartSession without an identity (\(payload.count) bytes)")
            }
            await startSession(start)
        case AssistantMessageType.netEvent:
            await turnMessage(payload)
        case AssistantMessageType.segmentHeader, AssistantMessageType.segmentBuffer:
            do {
                switch try segments.add(type, payload) {
                case .incomplete: break
                case .whole(let wholeType, let whole): await inner(wholeType, whole)
                case .dropped(let why): log(why)
                }
            } catch {
                log("an unreadable segmented message")
            }
        case AssistantMessageType.startInteraction:
            log("an older-style interaction start (\(payload.count) bytes); these glasses use StartSession")
        case AssistantMessageType.activeDeviceStateRequest:
            await activePhoneAsked()   // GlassesRequests.swift
        default:
            log("an envelope carrying type \(type) (\(payload.count) bytes)")
            glassesAsked(kind: "assistant envelope \(type)", payload: payload, isRequestType: false)
        }
    }

    /// An IDNM turn message. Only the glasses closing an interaction changes anything; the rest is logged.
    private func turnMessage(_ payload: [UInt8]) async {
        guard let message = (try? IdnmMessage.decode(payload)) ?? nil else {
            return log("an unreadable turn message (\(payload.count) bytes)")
        }
        if message.type == IdnmType.interactionClose {
            await glassesClosed(message.closedInteraction())
            return
        }
        let request = GlassesRequestName.find(in: message.payload)
        log("turn message \(message.type) from the glasses (\(message.payload.count) bytes)"
            + (request.map { ", \($0)" } ?? "") + (turn == nil ? ", no turn open" : ""))
        guard turn == nil || request != nil else { return }
        glassesAsked(kind: "turn message \(message.type)", payload: message.payload,
                     isRequestType: message.type == IdnmType.glassesRequest)
    }

    /// Something the glasses sent on their own: passed to the app by kind (with the request's event name when it has
    /// one).
    func glassesAsked(kind: String, payload: [UInt8], isRequestType: Bool) {
        let request = GlassesRequestName.find(in: payload)
        if request == GlassesRequestName.tarAlert, let timers = timerHooks.current {
            // A timer rang on the glasses (seen as turn message 6): the timers match it to the list they sent.
            timers.alert(payload)
            return
        }
        // A request for speech goes to the app with what it carries (GlassesRequests.swift).
        if isRequestType || request != nil, speechRequested(payload) { return }
        announce(request.map { "\(kind): \($0)" } ?? kind)
    }

    // MARK: Turns

    /// 1040: a wake. A repeat of the open turn's start, or of an ended turn's, is ignored; a late one for the open
    /// turn's session before the wearer spoke keeps the turn; anything else ends the open turn and opens one.
    private func startSession(_ start: StartSession) async {
        let key = StartKey(session: start.session, interaction: start.interaction)
        if endedStarts.contains(key) {
            return log("the glasses resent the StartSession of a turn that already ended; ignored")
        }
        if let open = turn {
            if open.starts.contains(key) {
                return log("\(open.id): the glasses repeated their StartSession; ignored")
            }
            // A same-session start while a follow-up listens keeps the follow-up and its deadline.
            if open.followUpInteraction != nil, open.owns(session: start.session) {
                return log("\(open.id): a StartSession during the follow-up; kept")
            }
            // A late StartSession for the session the turn already has (its microphone can come first), before the
            // wearer spoke: the same invocation, so the turn keeps its microphone rather than starting over.
            if open.owns(session: start.session), !open.speechStartSent {
                turn?.starts.insert(key)
                return log("\(open.id): a StartSession for the open turn's session before speech; kept")
            }
        }
        if turn != nil { await closeTurn(.newWake) }
        openTurn(session: start.session, interaction: start.interaction, cause: "StartSession")
    }

    private func openTurn(session: String, interaction: String, cause: String) {
        abortTurnlessOutputs(.cancelled)
        turnCount += 1
        let id = AssistantTurnID(raw: turnCount)
        turn = Turn(id: id, session: session, startInteraction: interaction)
        closedSessions.removeAll { $0 == session }
        log("\(id): wake (\(cause))")
        emit(.wake(id))
    }

    /// 5002 from the glasses: their microphone for a session. It can arrive without a StartSession, which then opens
    /// the turn.
    private func microphoneHeader(_ payload: [UInt8]) async {
        guard let header = try? MicrophoneHeader.decode(payload) else {
            return log("an unreadable microphone header (\(payload.count) bytes)")
        }
        guard !header.interaction.isEmpty else { return log("a microphone header without an interaction; ignored") }
        let session: String
        if !header.session.isEmpty {
            session = header.session
        } else if let open = turn {
            session = open.micSession ?? open.startSession
        } else {
            session = header.interaction
        }
        if closedSessions.contains(session) { return log("a late microphone header for an ended turn; ignored") }
        if let open = turn, !open.owns(session: session) {
            if open.micSession == nil, !open.speechStartSent {
                // The first microphone of a turn its StartSession just opened: the same invocation, whatever the
                // session ids say, so the app sees one wake. The answer uses this header's interaction.
                log("\(open.id): the microphone names a different session than StartSession; same turn")
            } else {
                await closeTurn(.newWake)
            }
        }
        if turn == nil {
            openTurn(session: session, interaction: header.interaction, cause: "microphone without StartSession")
        }
        guard var open = turn else { return }
        open.micSession = session
        if open.micOpen, open.micInteraction == header.interaction, open.micStream == header.stream {
            return log("\(open.id): the glasses repeated their microphone header; ignored")
        }
        if let known = open.micInteraction, known != header.interaction, open.finalSent {
            log("\(open.id): a second microphone interaction after the request; the turn keeps its own")
        } else {
            let before = open.interaction
            open.micInteraction = header.interaction
            // A new interaction after start of speech but before the request: it gets its own turn message 1 before
            // message 2: message 1 goes once per interaction.
            if open.interaction != before, open.speechStartSent, !open.finalSent {
                open.speechStartSent = false
                log("\(open.id): a new microphone interaction after start of speech; start of speech goes again")
            }
        }
        open.micStream = header.stream
        open.micOpen = true
        open.micChunks = 0
        open.decoder = MicrophoneDecoder()
        turn = open
        log("\(open.id): microphone open (encoding \(header.encoding), \(header.sampleRate) Hz)")
    }

    private func microphoneChunk(_ payload: [UInt8]) {
        guard var open = turn, open.micOpen else { return }
        open.micChunks += 1
        if open.micChunks == 1 {
            log("\(open.id): first microphone audio \(milliseconds(open.openedAt.duration(to: .now))) ms after the wake")
        }
        defer { turn = open }
        guard hasConsumer.current, let decoder = open.decoder else { return }
        let chunk = decoder.decode(payload)
        if let fault = chunk.fault {
            open.micFaults += 1
            if open.micFaults <= 3 { log("\(open.id): a microphone chunk did not parse (\(fault))") }
        }
        guard !chunk.samples.isEmpty else { return }
        if open.listening {
            emit(.micAudio(open.id, chunk.samples))
        } else {
            open.busySamples += chunk.samples.count
            emit(.micAudioWhileBusy(open.id, chunk.samples))
        }
    }

    private func microphoneEnded() {
        guard var open = turn, open.micOpen else { return }
        open.micOpen = false
        turn = open
        log("\(open.id): microphone ended (\(open.micChunks) chunks)")
        emit(.micEnded(open.id))
    }

    /// The glasses closed an interaction. Only the open turn's own id ends it.
    private func glassesClosed(_ interaction: String) async {
        for (key, output) in outputs where output.turn == nil && output.interaction == interaction {
            outputs[key]?.glassesClosed = true
            if output.streamEnded { output.settled.resolve(.success(.closedByGlasses)) }
        }
        guard let open = turn, !interaction.isEmpty, interaction == open.interaction else {
            return log("the glasses closed an interaction that isn't the open turn's")
        }
        await closeTurn(.closedByGlasses)
    }

    /// Ends the open turn: stops its keep-alive and reply, remembers its session, tells the app or the glasses.
    func closeTurn(_ end: TurnEnd) async {
        guard let open = turn else { return }
        turn = nil
        if !open.listening {
            log("\(open.id): \(String(format: "%.1f", Double(open.busySamples) / 16_000)) s of microphone audio arrived "
                + "since the last request")
        }
        // A timer list held back by the turn goes after the close (or right away when the glasses closed it).
        defer { timerHooks.current?.turnEnded() }
        open.keepAlive?.cancel()
        closedSessions.append(open.startSession)
        if let micSession = open.micSession, micSession != open.startSession { closedSessions.append(micSession) }
        if closedSessions.count > 16 { closedSessions.removeFirst(closedSessions.count - 16) }
        // Without its own interaction id a StartSession can't tell a resend from a new wake reusing the session.
        endedStarts.append(contentsOf: open.starts.filter { $0.interaction != $0.session })
        if endedStarts.count > 8 { endedStarts.removeFirst(endedStarts.count - 8) }
        for (key, output) in outputs where output.turn == open.id {
            if output.streamEnded {
                output.settled.resolve(.success(end == .closedByGlasses ? .closedByGlasses : .interrupted))
            } else {
                outputs[key]?.abort = end.replyError
                output.settled.resolve(.success(.interrupted))
            }
        }
        log("\(open.id): ended (\(end)) after \(milliseconds(open.openedAt.duration(to: .now))) ms")
        if end.tellsApp { emit(.turnClosed(open.id)) }
        guard end.closesOnGlasses, let reg = registration, let m0 = reg.m0 else { return }
        // A follow-up the wearer never started closes the interaction that was answered.
        let closing = open.followUpInteraction != nil && !open.speechStartSent
            ? (open.completedInteraction ?? open.interaction) : open.interaction
        do {
            try await send(reg.mux, m0, AssistantMessages.close(closing), type: AssistantMessageType.netEvent)
            log("\(open.id): closed on the glasses (turn message 11)")
        } catch {
            log("\(open.id): the close did not reach the glasses")
        }
    }

    // MARK: The app's calls

    func userSpeechStarted(_ id: AssistantTurnID) async {
        guard turn?.id == id else { return }
        do { try await sendSpeechStart(id) } catch {
            return log("\(id): start of speech not sent (\(ReGlassError.from(error)))")
        }
        startKeepAlive(id)
    }

    func finalTranscript(_ id: AssistantTurnID, _ text: String) async {
        guard var open = turn, open.id == id else { return }
        open.listening = false
        open.busySamples = 0
        turn = open
        log("\(id): request final (\(text.count) characters)")
        do { try await sendPreamble(id) } catch {
            return log("\(id): the request did not reach the glasses (\(ReGlassError.from(error)))")
        }
        startKeepAlive(id)
    }

    func holdTurn(_ id: AssistantTurnID) async {
        guard turn?.id == id else { return }
        do { try await sendPreamble(id) } catch {
            return log("\(id): the hold did not reach the glasses (\(ReGlassError.from(error)))")
        }
        startKeepAlive(id)
        log("\(id): the reply plays on the iPhone; the glasses wait")
    }

    func endTurn(_ id: AssistantTurnID) async {
        guard turn?.id == id else { return }
        await closeTurn(.endedByApp)
    }

    /// Start of speech (turn message 1), once per interaction.
    private func sendSpeechStart(_ id: AssistantTurnID) async throws {
        guard var open = turn, open.id == id, !open.speechStartSent else { return }
        guard let reg = registration, let m0 = reg.m0 else { throw ReGlassError.linkLost }
        open.speechStartSent = true
        turn = open
        try await send(reg.mux, m0, AssistantMessages.startOfUserSpeech(open.interaction), type: AssistantMessageType.netEvent)
        log("\(id): start of speech (turn message 1)")
    }

    /// Start of speech then final transcription (turn message 2), each once per interaction: what tells the glasses
    /// the request was understood.
    func sendPreamble(_ id: AssistantTurnID) async throws {
        try await sendSpeechStart(id)
        guard var open = turn, open.id == id else { throw ReGlassError.cancelled }
        guard !open.finalSent else { return }
        guard let reg = registration, let m0 = reg.m0 else { throw ReGlassError.linkLost }
        open.finalSent = true
        turn = open
        try await send(reg.mux, m0, AssistantMessages.finalTranscription(open.interaction), type: AssistantMessageType.netEvent)
        log("\(id): request understood (turn message 2)")
    }

    // MARK: Keep-alive

    /// "Still working" every 3 s, so the glasses (which give up after 20 s) keep waiting.
    func startKeepAlive(_ id: AssistantTurnID) {
        guard var open = turn, open.id == id, open.keepAlive == nil else { return }
        open.keepAlive = Task { await self.keepAlive(id) }
        turn = open
    }

    func stopKeepAlive(_ id: AssistantTurnID) {
        guard var open = turn, open.id == id else { return }
        open.keepAlive?.cancel()
        open.keepAlive = nil
        turn = open
    }

    private func keepAlive(_ id: AssistantTurnID) async {
        var seq: Int64 = 1
        while true {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard turn?.id == id, let reg = registration, let m0 = reg.m0 else { return }
            // A failed keep-alive is not fatal; the link's own failure ends the turn.
            try? await send(reg.mux, m0, AssistantMessages.keepAlive(seq), type: AssistantMessageType.netEvent)
            if seq == 1 || seq % 5 == 0 { log("\(id): still working (\(seq))") }
            seq += 1
        }
    }

    // MARK: Live translation 6-channel outward microphone (svc72 + s0 6100..6102)

    /// The glasses open live translation on svc72 with message 8 at link-up and listen for the start request
    /// (message 2) on the mirrored channel id.
    func receiveLiveTranslation(_ message: DataXMessage, from mux: DataXMultiplexer) async {
        guard !stopped else { return }
        let mirrored = DataXMultiplexer.mirror(message.info.channelId)
        liveTranslationMux = mux
        liveTranslationChannel = mirrored
        let type = message.info.messageType
        let payload = message.payload

        switch type {
        case LiveTranslationMessages.scopeCreatedHello:
            log(String(format: "live translation: channel ready (peer 0x%04x → mirror 0x%04x, %d bytes)",
                       message.info.channelId, mirrored, payload.count))
        case LiveTranslationMessages.translationAck:
            if let ack = LiveTranslationMessages.decodeAck(payload) {
                log("live translation: glasses answered TranslationAck (accepted: \(ack.accepted))")
                if !ack.accepted {
                    liveTranslationStartWaiter?.resolve(.success(false))
                    liveTranslationStartWaiter = nil
                }
            } else {
                log("live translation: unreadable TranslationAck (\(payload.count) bytes)")
            }
        case LiveTranslationMessages.inviteToJoin:
            if let sessionID = LiveTranslationMessages.decodeInviteSessionID(payload) {
                liveTranslationSessionID = sessionID
            }
            log("live translation: glasses echoed InviteToJoin (\(payload.count) bytes, session "
                + "\(liveTranslationSessionID != nil ? "recorded" : "missing")); sending TTSEnded to unmute 6-channel mic")
            try? await send(mux, mirrored, [], type: LiveTranslationMessages.ttsEnded)
        case LiveTranslationMessages.stoppingFromFrame, LiveTranslationMessages.endFromFrame:
            log("live translation: glasses ended session from frame (message \(type))")
            liveTranslationStartWaiter?.resolve(.success(false))
            liveTranslationStartWaiter = nil
            if liveTranslationMicOpen {
                liveTranslationMicOpen = false
                emit(.liveTranslationMicState(false))
            }
        default:
            log("live translation: message \(type) from the glasses (\(payload.count) bytes)")
        }
    }

    func startLiveTranslationMic(sourceLanguage: String, targetLanguage: String) async -> Bool {
        guard !stopped else { return false }
        if turn != nil {
            await closeTurn(.endedByApp)
        }
        // Give the glasses 150 ms to finish closing the assistant turn before requesting live translation
        // (app 6, use case 7) on svc72.
        try? await Task.sleep(for: .milliseconds(150))
        guard !stopped else { return false }
        guard let mux = liveTranslationMux ?? registration?.mux, let channel = liveTranslationChannel else {
            log("live translation: cannot start 6-channel mic (svc72 channel was not opened by the glasses)")
            return false
        }
        if liveTranslationMicOpen {
            await stopLiveTranslationMic()
        }
        let reqID = AssistantMessages.newID()
        liveTranslationRequestID = reqID
        let waiter = OneShot<Bool>()
        liveTranslationStartWaiter = waiter
        let invite = LiveTranslationMessages.inviteToJoin(selfLang: targetLanguage, otherLang: sourceLanguage,
                                                          requestID: reqID)
        log("live translation: sending InviteToJoin (\(sourceLanguage) → \(targetLanguage)) on channel "
            + String(format: "0x%04x", channel))
        do {
            try await send(mux, channel, invite, type: LiveTranslationMessages.inviteToJoin)
        } catch {
            liveTranslationStartWaiter = nil
            log("live translation: failed to send InviteToJoin (\(ReGlassError.from(error)))")
            return false
        }
        do {
            let started = try await withTimeout(. milliseconds(3_000), "live translation 6-channel mic start") {
                try await waiter.value()
            }
            liveTranslationStartWaiter = nil
            return started
        } catch {
            liveTranslationStartWaiter = nil
            log("live translation: timed out waiting for 6102 stream header from the glasses")
            return false
        }
    }

    func stopLiveTranslationMic() async {
        liveTranslationStartWaiter?.resolve(.success(false))
        liveTranslationStartWaiter = nil
        let wasOpen = liveTranslationMicOpen
        liveTranslationMicOpen = false
        liveTranslationDecoder = nil
        if let mux = liveTranslationMux ?? registration?.mux,
           let channel = liveTranslationChannel,
           let sessionID = liveTranslationSessionID {
            let reqID = AssistantMessages.newID()
            let stop = LiveTranslationMessages.stopRequest(requestID: reqID, sessionID: sessionID)
            try? await send(mux, channel, stop, type: LiveTranslationMessages.stopRequest)
            log("live translation: sent TranslationStopRequest")
        }
        liveTranslationSessionID = nil
        liveTranslationRequestID = nil
        if wasOpen {
            emit(.liveTranslationMicState(false))
        }
    }

    private func liveTranslationHeader(_ payload: [UInt8]) async {
        if let sessionID = LiveTranslationMessages.decodeCaptureStartSessionID(payload) {
            liveTranslationSessionID = sessionID
        }
        liveTranslationMicOpen = true
        liveTranslationMutedChunks = 0
        liveTranslationFaults = 0
        liveTranslationDecoder = LiveTranslationMicDecoder()
        log("live translation: 6-channel outward microphone open (6102)")
        if let mux = liveTranslationMux ?? registration?.mux, let channel = liveTranslationChannel {
            // Tell the glasses that speech playback has ended so they unmute the outward microphones.
            try? await send(mux, channel, [], type: LiveTranslationMessages.ttsEnded)
        }
        liveTranslationStartWaiter?.resolve(.success(true))
        liveTranslationStartWaiter = nil
        emit(.liveTranslationMicState(true))
    }

    private func liveTranslationChunk(_ payload: [UInt8]) async {
        guard liveTranslationMicOpen, hasConsumer.current, let decoder = liveTranslationDecoder else { return }
        let chunk = decoder.decode(payload)
        if let fault = chunk.fault {
            liveTranslationFaults += 1
            if liveTranslationFaults <= 3 {
                log("live translation: a 6-channel packet did not parse (\(fault))")
            }
        }
        if chunk.isMutedReplacement {
            liveTranslationMutedChunks += 1
            if liveTranslationMutedChunks == 1 || liveTranslationMutedChunks % 25 == 0 {
                if liveTranslationMutedChunks == 1 {
                    log("live translation: the glasses sent their muted replacement frame; sending TTSEnded to unmute")
                }
                if let mux = liveTranslationMux ?? registration?.mux, let channel = liveTranslationChannel {
                    try? await send(mux, channel, [], type: LiveTranslationMessages.ttsEnded)
                }
            }
        }
        guard !chunk.channels.isEmpty else { return }
        emit(.liveTranslationMicAudio(chunk.channels))
    }

    private func liveTranslationEnded() {
        guard liveTranslationMicOpen else { return }
        liveTranslationMicOpen = false
        liveTranslationDecoder = nil
        log("live translation: 6-channel outward microphone ended (6101)")
        emit(.liveTranslationMicState(false))
    }

    // MARK: Helpers

    /// Sends in call order: each send waits for the one before it, so reply audio, acks and turn messages made
    /// from different tasks can't overtake each other. Any failure means the link is going: `.linkLost`.
    func send(_ mux: DataXMultiplexer, _ channel: Int, _ payload: [UInt8], type: Int, service: Int? = nil) async throws {
        let previous = outboxTail
        let task = Task {
            _ = await previous?.result
            try await mux.send(channel, payload, messageType: type, serviceId: service)
        }
        outboxTail = task
        do { try await task.value } catch { throw ReGlassError.linkLost }
    }

    func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        emit(.availability(value))
    }

    func emit(_ event: AssistantEvent) {
        eventSink.yield(event)
    }

    func log(_ line: String) {
        kitLog("assistant", line)
    }

    /// Something the glasses said on their own: passed to the app by kind, at most every 5 s per kind. True when it
    /// was passed on.
    @discardableResult
    func announce(_ kind: String) -> Bool {
        let now = ContinuousClock.now
        if let last = announcementsSeen[kind], last.duration(to: now) < .seconds(5) { return false }
        if announcementsSeen.count > 64 { announcementsSeen.removeAll() }
        announcementsSeen[kind] = now
        emit(.glassesAnnouncement(kind: kind))
        emit(.glassesReport(.unrecognised(kind)))
        return true
    }
}

func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
}
