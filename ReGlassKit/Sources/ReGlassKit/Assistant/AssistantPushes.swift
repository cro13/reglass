import Foundation

// Speech with no turn open: announcements (timers, reminders, anything the app says on its own) as reply streams the
// glasses play without a wake word. Nothing here runs unless the app asks, except the passive logging of what the
// glasses send on their own. Results and every svc15 message type the glasses send meanwhile are logged (types and
// sizes only).

extension AssistantService {
    /// Both players: the messaging player, then (unless that played) the assistant's with the same audio.
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>) async -> AssistantPushResult {
        if let refusal = pushUnavailable() { return logged(refusal) }
        let buffer = ReplyBuffer(keepsAll: true)
        let feeder = startFeeding(audio, into: buffer)
        defer { feeder.cancel() }
        let first = await push(buffer, playback: .messaging)
        switch first {
        case .played, .unavailable: return first
        case .refused, .noAnswer: break
        }
        await feeder.value
        guard let again = buffer.replay() else { return first }
        return await push(again, playback: .assistant)
    }

    /// One player. `listenAfter`: shaped like a turn's reply so the glasses may open their microphone (which
    /// opens a turn) without a wake word: the turn's preamble (start of speech, final transcription) under a fresh
    /// interaction, the assistant's player whatever `playback` says, and the answer message expecting a follow-up.
    /// (The messaging player with only the follow-up answer played but didn't listen.) If the glasses
    /// refuse that, the same audio plays on `playback` without listening, so the wearer still hears it.
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>, playback: AssistantPlayback,
                               listenAfter: Bool) async -> AssistantPushResult {
        if let refusal = pushUnavailable() { return logged(refusal) }
        let buffer = ReplyBuffer(keepsAll: listenAfter)
        let feeder = startFeeding(audio, into: buffer)
        defer { feeder.cancel() }
        guard listenAfter else { return await push(buffer, playback: playback) }
        let first = await push(buffer, playback: .assistant, listenAfter: true)
        guard case .refused = first else { return first }
        await feeder.value
        guard let again = buffer.replay() else { return first }
        return await push(again, playback: playback)
    }

    /// A reply stream with no turn open, under a fresh interaction id. Only the stream goes out (header, audio,
    /// 6000): no turn messages, so nothing claims a turn the glasses never opened. `.played` on a matching 6001,
    /// `.refused` on a DataX status on the assistant's channels or the glasses closing that interaction,
    /// `.noAnswer` when nothing came within 10 s of the stream's end.
    private func push(_ buffer: ReplyBuffer, playback: AssistantPlayback, listenAfter: Bool = false) async -> AssistantPushResult {
        if let refusal = pushUnavailable() { return logged(refusal) }
        pushRunning = true
        defer { pushRunning = false }
        log("push: a reply stream with no turn open, \(playback)\(listenAfter ? ", asking the glasses to listen after it" : "")")
        return await answer(buffer, interaction: AssistantMessages.newID(), playback: playback, label: "push",
                            listenAfter: listenAfter)
    }

    /// Passive: a message from a service the live connection doesn't otherwise use. Logged and passed to the
    /// app by kind (service and type numbers), never content.
    func observe(service: Int, type: Int, size: Int) {
        let kind = "service \(service) message \(type)"
        if announce(kind) { log("the glasses sent \(kind) on their own (\(size) bytes)") }
    }

    /// A DataX status from svc46 (the glasses' notification service).
    func notificationStatus(_ status: Int) {
        log(String(format: "service 46 answered status 0x%04lx", status))
    }

    // MARK: Helpers

    private func pushUnavailable() -> AssistantPushResult? {
        guard !stopped, let reg = registration, reg.registered, reg.s0 != nil else {
            return .unavailable("the glasses' assistant isn't connected")
        }
        guard turn == nil else { return .unavailable("a turn is open") }
        guard playingOutput == nil, outputs.isEmpty else { return .unavailable("a reply is playing") }
        return nil
    }

    /// Streams `buffer` as a turn-less reply and waits for the glasses' verdict. `listenAfter`: then sends the
    /// answer message that expects a follow-up; a turn the glasses open meanwhile (their microphone) means it played.
    private func answer(_ buffer: ReplyBuffer, interaction: String, playback: AssistantPlayback,
                        label: String, listenAfter: Bool = false) async -> AssistantPushResult {
        let outputID = makeOutput(turn: nil, interaction: interaction)
        defer { forgetOutput(outputID) }
        pushRunning = true
        let turnsBefore = turnCount
        do {
            if listenAfter, let reg = registration, let m0 = reg.m0 {
                try await send(reg.mux, m0, AssistantMessages.startOfUserSpeech(interaction), type: AssistantMessageType.netEvent)
                try await send(reg.mux, m0, AssistantMessages.finalTranscription(interaction), type: AssistantMessageType.netEvent)
                log("\(label): sent a turn's preamble first (turn messages 1 and 2)")
            }
            let stats = try await streamReply(outputID, buffer: buffer, playback: playback, began: .now, label: label)
            log("\(label): \(stats.frames * 20) ms sent, \(stats.silenceFrames) silence frames")
            if listenAfter, let reg = registration, let m0 = reg.m0 {
                do {
                    try await send(reg.mux, m0, AssistantMessages.answer(interaction, expectFollowUp: true),
                                   type: AssistantMessageType.netEvent)
                    log("\(label): asked the glasses to listen after it (turn message 5, expects a follow-up)")
                } catch {
                    log("\(label): the follow-up request did not reach the glasses")
                }
            }
        } catch {
            let output = outputs[outputID]
            if let refusal = output?.refusal { return pushRefused(refusal, playback) }
            if output?.glassesClosed == true { return logged(.refused("the glasses closed the interaction"), playback) }
            if let kitError = error as? ReGlassError, kitError == .linkLost { return logged(.unavailable("the link dropped"), playback) }
            if let kitError = error as? ReGlassError, kitError == .cancelled { return logged(.unavailable("interrupted"), playback) }
            if error is CancellationError { return logged(.unavailable("interrupted"), playback) }
            return logged(.unavailable("the voice gave no audio"), playback)
        }
        // Every packet went out. A turn the wearer opens before the glasses confirm (they heard it and said "OK
        // ReGlass") still counts as played, so the app doesn't say it again before the reply.
        let wait = !listenAfter && playback != .assistant ? Self.messagingPlaybackWait : Self.playbackWait
        let end: PlaybackEnd
        do { end = try await playbackEnd(outputID, wait: wait) } catch {
            if turnCount > turnsBefore { return listenAfter ? listened(label, playback) : playedBeforeTurn(label, playback) }
            return logged(.unavailable("interrupted"), playback)
        }
        if turnCount > turnsBefore { return listenAfter ? listened(label, playback) : playedBeforeTurn(label, playback) }
        switch end {
        case .consumed:
            log("\(label): playback confirmed (interaction id \(outputs[outputID]?.consumedID ?? "none"))")
            if listenAfter { watchForListening(label, since: turnsBefore) }
            return logged(.played, playback)
        case .refused(let status): return pushRefused(status, playback)
        case .closedByGlasses: return logged(.refused("the glasses closed the interaction"), playback)
        case .unconfirmed, .interrupted: return logged(.noAnswer, playback)
        }
    }

    /// A turn opened after the whole announcement went out but before the glasses confirmed playback.
    private func playedBeforeTurn(_ label: String, _ playback: AssistantPlayback) -> AssistantPushResult {
        log("\(label): a turn opened after it was sent, before playback was confirmed; counted as played")
        return logged(.played, playback)
    }

    /// The glasses opened a turn (their microphone) right after an announcement that asked them to listen.
    private func listened(_ label: String, _ playback: AssistantPlayback) -> AssistantPushResult {
        log("\(label): the glasses opened the microphone after it (no wake word)")
        return logged(.played, playback)
    }

    /// Logs whether the glasses open a turn within 5 s of a confirmed announcement that asked them to listen. Doesn't
    /// hold up the caller: the app marks what was said as soon as the push returns.
    private func watchForListening(_ label: String, since turnsBefore: UInt64) {
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if await self.turnCount > turnsBefore {
                    await self.log("\(label): the glasses opened the microphone after it (no wake word)")
                    return
                }
            }
            await self?.log("\(label): the glasses didn't open the microphone within 5 s of it")
        }
    }

    /// svc46 sends go through the same ordered outbox as everything else.
    private func sendOnService(_ mux: DataXMultiplexer, _ service: Int, _ type: Int, _ payload: [UInt8]) async throws {
        let previous = outboxTail
        let task = Task {
            _ = await previous?.result
            try await mux.sendOnService(service, type, payload)
        }
        outboxTail = task
        do { try await task.value } catch { throw ReGlassError.linkLost }
    }

    private func pushRefused(_ status: Int, _ playback: AssistantPlayback) -> AssistantPushResult {
        logged(.refused(String(format: "status 0x%04lx", status)), playback)
    }

    private func logged(_ result: AssistantPushResult, _ playback: AssistantPlayback? = nil) -> AssistantPushResult {
        log("push result\(playback.map { " (\($0))" } ?? ""): \(result)")
        return result
    }
}

