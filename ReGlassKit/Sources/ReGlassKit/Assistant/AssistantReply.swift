import Foundation

// Replies: the app's 24 kHz PCM, encoded and paced in real time on s0, then the answer message, then the wait for
// the glasses' 6001. Order and timing: header 5002, every audio message 5003 with two 20 ms packets, one message
// every 40 ms, 6000, then turn message 5 (the answer goes after the stream end on this path), then 6001 or a 10 s
// fallback, then turn message 11 for a reply that ends the turn. Audio is taken as it comes, not after the whole
// reply is ready.

extension AssistantService {
    /// How much reply audio is buffered before the stream starts: 450 ms, so a voice that delivers in bursts (its
    /// first chunk especially) doesn't stutter at the start.
    static let replyPreroll = AssistantMessages.replySampleRate * 450 / 1_000
    /// Turn-less messaging pushes (the real-time interpreter and announcements): 160 ms is four 40 ms messages,
    /// enough to cover WebSocket jitter while starting playback nearly 300 ms sooner.
    static let messagingPreroll = AssistantMessages.replySampleRate * 160 / 1_000
    /// The real-time interpreter's voice on the live-translation player: 16 kbps (40-byte packets, 2 kB/s) instead of
    /// the usual 32, so fewer bytes share the link while the six microphones stream; whether that helps is unproven.
    static let liveTranslationReplyBitrate = 16_000
    /// The longest run of silence padding once audio has started. A voice behind by less pauses naturally; past it
    /// (a stalled network), the reply ends there instead of streaming dead air.
    static let maxReplyGap: Duration = .milliseconds(2_500)
    /// How long after the stream's end the glasses get to confirm playback.
    static let playbackWait: Duration = .seconds(10)
    /// Turn-less messaging pushes are already paced in real time; if 6001 is missed, release the queue quickly.
    static let messagingPlaybackWait: Duration = .milliseconds(1_500)

    struct ReplyStats {
        var frames = 0
        var silenceFrames = 0
        /// The app's stream threw, or stalled past `maxReplyGap`, after audio had started; the reply ended with what
        /// came before.
        var producerFailure: Error?
    }

    func speak(_ id: AssistantTurnID, audio: AsyncThrowingStream<[Int16], Error>, expectFollowUp: Bool) async throws {
        guard !stopped, let reg = registration, reg.registered, reg.s0 != nil else { throw ReGlassError.linkLost }
        guard turn?.id == id else { throw ReGlassError.cancelled }
        try checkNoReply(for: id)
        let began = ContinuousClock.now
        do {
            // Start of speech and the final transcription go first if the app didn't send them.
            try await sendPreamble(id)
        } catch {
            throw ReGlassError.from(error)
        }
        guard let open = turn, open.id == id else { throw ReGlassError.cancelled }
        // Again after the await: a second `speak` for this turn may have got here first. Nothing suspends from here
        // to `makeOutput`, so a turn has at most one reply stream.
        try checkNoReply(for: id)
        let interaction = open.interaction
        let outputID = makeOutput(turn: id, interaction: interaction)
        startKeepAlive(id)
        let buffer = ReplyBuffer()
        let feeder = startFeeding(audio, into: buffer)
        defer {
            feeder.cancel()
            forgetOutput(outputID)
        }

        let stats: ReplyStats
        do {
            stats = try await streamReply(outputID, buffer: buffer, playback: .assistant, began: began, label: "\(id)")
        } catch {
            // No "still working" after a throw (another `speak` starts it again).
            stopKeepAlive(id)
            if error is CancellationError { throw ReGlassError.cancelled }
            // A ReGlassError as it came; anything else is the app's own stream failing before any audio.
            throw error
        }

        // The answer, after the stream end. Its loss is logged, not thrown: the audio already went out.
        if let reg = registration, let m0 = reg.m0 {
            do {
                try await send(reg.mux, m0, AssistantMessages.answer(interaction, expectFollowUp: expectFollowUp),
                               type: AssistantMessageType.netEvent)
            } catch {
                log("\(id): the answer message did not reach the glasses")
            }
        }
        stopKeepAlive(id)
        log("\(id): reply sent: \(stats.frames * 20) ms in \(stats.frames) packets, \(stats.silenceFrames) of them "
            + "silence; the answer \(expectFollowUp ? "expects a follow-up" : "ends the turn") (turn message 5)")

        let end = try await playbackEnd(outputID)
        let sinceEnd = outputs[outputID]?.endedAt.map { milliseconds($0.duration(to: .now)) } ?? 0
        switch end {
        case .consumed:
            log("\(id): the glasses played the reply (\(sinceEnd) ms after the stream ended; "
                + "interaction id \(outputs[outputID]?.consumedID ?? "none"))")
        case .closedByGlasses: log("\(id): the glasses closed the turn after the reply")
        case .unconfirmed: log("\(id): no playback confirmation within 10 s")
        case .interrupted, .refused: log("\(id): the turn ended before the glasses confirmed playback")
        }
        if turn?.id == id {
            if expectFollowUp { openFollowUp(id, after: interaction) } else { await closeTurn(.replyFinished) }
        }
        if let failure = stats.producerFailure { throw failure }
    }

    /// Streams one reply on s0 from `buffer` (which the caller is filling): pre-roll, header, real-time audio, 6000.
    /// Throws `.cancelled` / `.linkLost` when the turn or link goes, the app's own error when its stream fails before
    /// any audio.
    func streamReply(_ outputID: Int, buffer: ReplyBuffer, playback: AssistantPlayback, began: ContinuousClock.Instant,
                     label: String) async throws -> ReplyStats {
        guard let reg = registration, let s0 = reg.s0 else { throw ReGlassError.linkLost }
        let mux = reg.mux
        let encoder = try ReplyEncoder(bitrate: playback == .liveTranslation ? Self.liveTranslationReplyBitrate
                                                                             : replyBitrate)
        let preroll = playback != .assistant ? Self.messagingPreroll : Self.replyPreroll

        while !buffer.isReady(preroll: preroll) {
            try checkOutput(outputID)
            try await Task.sleep(for: .milliseconds(10))
        }
        try checkOutput(outputID)
        if buffer.received == 0 {
            if let failure = buffer.failure { throw failure }
            throw ReGlassError.protocolFailure("the reply had no audio")
        }
        guard let interaction = outputs[outputID]?.interaction else { throw ReGlassError.cancelled }

        playingOutput = outputID
        outputs[outputID]?.headerSent = true
        try await send(mux, s0, AssistantMessages.replyHeader(interaction, bitrate: encoder.bitrate, playback: playback),
                       type: AssistantMessageType.streamHeader)
        log("\(label): reply stream started \(milliseconds(began.duration(to: .now))) ms after the reply was handed over "
            + "(CELT \(encoder.bitrate) bps\(playback == .assistant ? "" : ", \(playback)"))")

        var stats = ReplyStats()
        let start = ContinuousClock.now
        let silence = [Int16](repeating: 0, count: AssistantMessages.replyFrameSamples)
        let maxSilentFrames = milliseconds(Self.maxReplyGap) / 20
        var audioStarted = false
        var silentRun = 0
        var stalled = false
        do {
            pacing: while true {
                try checkOutput(outputID)
                var packets: [[UInt8]] = []
                frames: while packets.count < 2 {
                    switch buffer.nextFrame(size: AssistantMessages.replyFrameSamples, flush: encoder.lookahead) {
                    case .audio(let frame):
                        packets.append(try encoder.encode(frame))
                        audioStarted = true
                        silentRun = 0
                    case .silence:
                        packets.append(try encoder.encode(silence))
                        stats.silenceFrames += 1
                        if audioStarted { silentRun += 1 }
                    case .end:
                        break frames
                    }
                }
                if packets.isEmpty { break pacing }
                try await send(mux, s0, AssistantMessages.replyAudio(packets), type: AssistantMessageType.streamAudio)
                stats.frames += packets.count
                if packets.count < 2 { break pacing }
                // The voice stalled: more padding would only be dead air. The reply ends here, as a voice failure.
                if silentRun >= maxSilentFrames {
                    stalled = true
                    break pacing
                }
                // Real time against the stream's start, so a late wake-up doesn't push every later message back.
                try await Task.sleep(until: start.advanced(by: .milliseconds(20 * stats.frames)),
                                     tolerance: .milliseconds(2), clock: .continuous)
            }
            try checkOutput(outputID)
        } catch {
            // Stopped mid-stream: end the stream rather than leave it hanging, unless the turn or link went.
            if !lostTurnOrLink(error, outputID) {
                try? await send(mux, s0, [], type: AssistantMessageType.streamEnd)
                log("\(label): the reply stopped mid-stream; stream ended")
            }
            throw error
        }
        try await send(mux, s0, [], type: AssistantMessageType.streamEnd)
        outputs[outputID]?.streamEnded = true
        outputs[outputID]?.endedAt = .now
        if stalled {
            stats.producerFailure = ReGlassError.timedOut("the reply audio")
            log("\(label): reply stalled: ended after "
                + "\(String(format: "%.1f", Double(milliseconds(Self.maxReplyGap)) / 1_000)) s of silence")
        } else {
            stats.producerFailure = buffer.failure
            if stats.producerFailure != nil { log("\(label): the voice failed mid-reply; the reply ended with what came") }
        }
        return stats
    }

    /// Whether a reply stopped mid-stream goes without 6000: when its turn ended or the link
    /// or the assistant's channels went. Anything else (the app cancelling, an encoder fault, a wake or a status
    /// stopping a turn-less push) ends the stream.
    private func lostTurnOrLink(_ error: Error, _ outputID: Int) -> Bool {
        if let kitError = error as? ReGlassError, kitError == .linkLost { return true }
        guard !stopped, let output = outputs[outputID] else { return true }
        if output.abort == .linkLost { return true }
        return output.turn != nil && output.abort != nil
    }

    /// A turn has at most one reply, and none may start while any reply is playing.
    private func checkNoReply(for id: AssistantTurnID) throws {
        guard !outputs.values.contains(where: { $0.turn == id }), playingOutput == nil else {
            throw ReGlassError.protocolFailure("a reply is already playing")
        }
    }

    /// Waits for the glasses to confirm playback (6001), up to `wait` after the stream's end. Once the whole reply has
    /// gone out, the turn or link going away no longer fails it.
    func playbackEnd(_ outputID: Int, wait: Duration = AssistantService.playbackWait) async throws -> PlaybackEnd {
        guard let settled = outputs[outputID]?.settled else { return .interrupted }
        do {
            return try await withTimeout(wait, "playback") { try await settled.value() }
        } catch ReGlassError.timedOut {
            return .unconfirmed
        } catch {
            throw ReGlassError.cancelled
        }
    }

    /// 6001. It answers the reply whose header went out last, when it names that reply's interaction or none. One
    /// that comes before the stream's end still counts.
    func playbackConsumed(_ payload: [UInt8]) {
        let named = consumedInteraction(payload)
        guard let id = playingOutput, let output = outputs[id], named.isEmpty || named == output.interaction else {
            let playing = playingOutput.flatMap { outputs[$0] } != nil
            return log("the glasses finished playing something that isn't the current reply"
                       + (playing ? " (interaction id no match)" : " (no reply playing)"))
        }
        guard !output.consumed else { return }
        outputs[id]?.consumed = true
        outputs[id]?.consumedID = named.isEmpty ? "none" : "matched"
        if !output.streamEnded { log("the glasses confirmed playback before the reply stream ended") }
        output.settled.resolve(.success(.consumed))
    }

    func checkOutput(_ id: Int) throws {
        guard !stopped, let output = outputs[id] else { throw ReGlassError.cancelled }
        if let abort = output.abort { throw abort }
        try Task.checkCancellation()
    }

    func makeOutput(turn: AssistantTurnID?, interaction: String) -> Int {
        outputCount += 1
        outputs[outputCount] = Output(id: outputCount, turn: turn, interaction: interaction)
        return outputCount
    }

    func forgetOutput(_ id: Int) {
        outputs[id] = nil
        if playingOutput == id { playingOutput = nil }
    }

    /// Replies with no turn (pushes) end when a turn opens (the pacer then still sends 6000) or the link
    /// goes (it doesn't).
    func abortTurnlessOutputs(_ error: ReGlassError) {
        for (key, output) in outputs where output.turn == nil {
            if output.streamEnded {
                output.settled.resolve(.success(.interrupted))
            } else {
                outputs[key]?.abort = error
                output.settled.resolve(.success(.interrupted))
            }
        }
    }

    /// A DataX status on the assistant's channels while a turn-less reply is out: the glasses refused it. One still
    /// streaming stops (with 6000, unless the status also closed the channels).
    func refuseTurnlessOutputs(_ status: Int) {
        for (key, output) in outputs where output.turn == nil && output.headerSent {
            outputs[key]?.refusal = status
            if !output.streamEnded, output.abort == nil { outputs[key]?.abort = .cancelled }
            output.settled.resolve(.success(.refused(status)))
        }
    }

    /// A reply that expects a follow-up keeps the turn open with a new interaction for the next request, and
    /// microphone audio flows to the app again (the app times the follow-up and calls `endTurn`).
    private func openFollowUp(_ id: AssistantTurnID, after answered: String) {
        guard var open = turn, open.id == id else { return }
        open.completedInteraction = answered
        open.followUpInteraction = AssistantMessages.newID()
        open.speechStartSent = false
        open.finalSent = false
        open.listening = true
        let busy = open.busySamples
        open.busySamples = 0
        turn = open
        log("\(id): listening for a follow-up (\(String(format: "%.1f", Double(busy) / 16_000)) s of microphone audio "
            + "arrived since the request)")
    }
}
