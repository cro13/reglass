import Foundation

// The contract between ReGlassKit's assistant service (svc15) and the app's assistant.
// ReGlassKit implements `GlassesAssistantLink`; the app codes against it. Transcripts, replies and audio are never
// logged: only states, sizes and timings.

/// One turn the glasses opened: a wake word was heard. Opaque to the app.
public struct AssistantTurnID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
    public var description: String { "turn \(raw)" }
}

/// What the glasses' assistant service tells the app.
public enum AssistantEvent: Sendable {
    /// The assistant service is registered on the current link (true) or the link went away (false).
    case availability(Bool)
    /// The glasses opened a turn (wake word). Mic audio for it follows.
    case wake(AssistantTurnID)
    /// The wearer's voice for `turn`: 16 kHz mono Int16 PCM, in order.
    case micAudio(AssistantTurnID, [Int16])
    /// Microphone audio for `turn` while it isn't listening for a request (Claude thinking, the reply speaking), same
    /// format. ReGlassKit decides nothing with it; the app may spot a barge-in ("Hey Meta" over the reply) in it. It
    /// includes the reply's own voice from the glasses' speakers.
    case micAudioWhileBusy(AssistantTurnID, [Int16])
    /// The glasses stopped streaming the microphone for `turn`.
    case micEnded(AssistantTurnID)
    /// The glasses ended `turn` (cancelled, timed out, closed, or a new wake). Stop working on it.
    case turnClosed(AssistantTurnID)
    /// Outward microphone audio from live translation (svc72, s0 message 6100). The 16 kHz, 6-channel stream
    /// uses mode `0x305` and preserves the wearer's voice.
    case liveTranslationMicAudio([[Int16]])
    /// The glasses' live-translation 6-channel outward microphone stream opened (`true`, on `6102`) or ended
    /// (`false`, on `6101` or `EndConversationFromFrame`).
    case liveTranslationMicState(Bool)
    /// The glasses announced or asked for something on their own, such as an incoming message. `kind` is a
    /// log-safe name (message type), never content.
    case glassesAnnouncement(kind: String)
    /// Something the glasses asked or reported on their own, decoded (`GlassesRequests.swift`). A speech request's
    /// fields are content: show them, never log them.
    case glassesReport(GlassesReport)
}

/// Which of the glasses' players a reply stream asks for: field 19 of the 5002 header. The glasses' firmware maps
/// it to a playback owner (1 → assistant, 2 → messaging, 4 → live translation LST).
public enum AssistantPlayback: Sendable, Equatable {
    /// 1: the assistant's player. Every normal reply uses it (proven on these glasses).
    case assistant
    /// 2: the messaging player for notification announcements. Playback through this route is unverified.
    case messaging
    /// 4 selects the live-translation player (use case 2), which plays while app 6 streams the outward microphone.
    case liveTranslation
}

/// The outcome of a push with no turn open (`pushSpeechWithoutTurn`).
public enum AssistantPushResult: Sendable, Equatable {
    /// The glasses confirmed they played it.
    case played
    /// The glasses refused it (log-safe reason).
    case refused(String)
    /// Sent, but the glasses never confirmed or refused.
    case noAnswer
    /// Not possible right now or not implemented (log-safe reason).
    case unavailable(String)
}

/// The glasses' assistant service on the live link. One consumer of `events`.
public protocol GlassesAssistantLink: AnyObject, Sendable {
    /// Events for the app, for as long as the link object lives.
    var events: AsyncStream<AssistantEvent> { get }

    /// The wearer started speaking in `turn`.
    func userSpeechStarted(_ turn: AssistantTurnID) async

    /// The final transcript of the wearer's request. ReGlassKit tells the glasses the request was understood and then
    /// keeps the turn alive ("still working", every 3 s) until `speak` or `endTurn`. The text is never logged.
    func finalTranscript(_ turn: AssistantTurnID, _ text: String) async

    /// Speaks a reply: 24 kHz mono Int16 PCM chunks as the voice produces them. ReGlassKit encodes Opus CELT CBR at the
    /// glasses' bitrate, paces it in real time and ends the stream. Returns when the glasses confirm playback, or
    /// 10 s after the stream ended without that. `expectFollowUp` asks the glasses to keep listening afterwards.
    /// Throws `ReGlassError.linkLost` or `ReGlassError.cancelled` if the link or turn goes away.
    ///
    /// Details: audio starts once 450 ms is buffered (or the stream finished); if the voice falls behind, silence
    /// holds real time for up to 2.5 s; past that the reply ends there and `ReGlassError.timedOut` is thrown after the
    /// wait, as for a voice failing mid-reply. A reply with `expectFollowUp == false` also closes the turn on the
    /// glasses once played, so a later `endTurn` does nothing. With `true` the turn stays open under a
    /// new interaction and microphone audio flows again; the app times the follow-up and calls `endTurn`. If `audio`
    /// throws before any audio went out, nothing is sent and its error is rethrown (the app may speak again); if it
    /// throws later, the reply ends with what came and its error is rethrown after the wait. Once the whole reply
    /// went out, the turn or link going away no longer throws (playback is then unconfirmed).
    func speak(_ turn: AssistantTurnID, audio: AsyncThrowingStream<[Int16], Error>, expectFollowUp: Bool) async throws

    /// The reply plays somewhere else (the iPhone's audio route): the glasses are told the request was understood, if
    /// they weren't yet, and kept waiting ("still working", every 3 s) until `speak` or `endTurn`, as while Claude
    /// works. The app then ends the reply with a short `speak`, so the glasses listen or close as after any reply.
    func holdTurn(_ turn: AssistantTurnID) async

    /// Ends `turn` on the glasses.
    func endTurn(_ turn: AssistantTurnID) async

    /// Requests outward live-translation capture with svc72 message 2. The s0 stream uses messages 6102, 6100 and
    /// 6101 for 16 kHz, 6-channel audio in mode `0x305`, bypassing the mono beamformer. Returns true once the
    /// glasses accept and open the stream.
    func startLiveTranslationMic(sourceLanguage: String, targetLanguage: String) async -> Bool

    /// Stops the glasses' 6-channel outward live-translation microphone with svc72 message 9.
    func stopLiveTranslationMic() async

    // MARK: Speech with no turn open

    /// Tries to make the glasses play `audio` (24 kHz mono Int16 PCM) with no turn open, over the assistant channel.
    /// Tries the messaging player first and, unless that played, the assistant's player with the same audio (so the
    /// wearer may hear it twice). The log says which variant did what.
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>) async -> AssistantPushResult

    /// As `pushSpeechWithoutTurn(audio:)`, with one player only. `listenAfter`: asks the glasses to listen after it,
    /// as a reply that expects a follow-up does; if they do, their microphone opens a turn (`.wake`) without a wake
    /// word. Whether they do is logged.
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>, playback: AssistantPlayback,
                               listenAfter: Bool) async -> AssistantPushResult

}

public extension GlassesAssistantLink {
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>, playback: AssistantPlayback) async -> AssistantPushResult {
        await pushSpeechWithoutTurn(audio: audio, playback: playback, listenAfter: false)
    }
}
