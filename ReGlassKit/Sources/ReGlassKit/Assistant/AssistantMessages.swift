import Foundation

// The Audio glasses' assistant service uses protobuf IDNM turn messages (1010) and Opus stream
// headers, audio and end markers (5002, 5003 and 6000) on svc15.

/// svc15 message types.
enum AssistantMessageType {
    /// Companion resource: this phone, `{1: "<epoch ms>-<uuid>"}`.
    static let pairedDevice = 11
    /// Registration of the message channel (m0), and its answer.
    static let initMessageRequest = 1000
    static let initMessageResponse = 1001
    /// A message too big for one frame: `{1 type, 2 size, 3 id}`, then pieces `{1 bytes, 2 id, 3 last}`.
    static let segmentHeader = 1002
    static let segmentBuffer = 1003
    /// Carries one IDNM turn message.
    static let netEvent = 1010
    static let deviceActive = 1016
    /// The older interaction start (camera glasses); not expected here.
    static let startInteraction = 1023
    static let runningLocale = 1026
    static let numberOfDevicesPaired = 1029
    static let airResourcesUnavailable = 1031
    static let airResourcesAvailable = 1032
    static let liveModeAirResourcesUnavailable = 1038
    static let liveModeAirResourcesAvailable = 1039
    /// The glasses heard the wake word: `{1 session, 4 interaction}`.
    static let startSession = 1040
    /// Registration of the stream channel (s0), and its answer.
    static let initStreamRequest = 5000
    static let initStreamResponse = 5001
    static let streamHeader = 5002
    static let streamAudio = 5003
    /// Text `<stream>_<interaction>_<pcm bytes>_<ms>`: what the glasses decoded of a reply.
    static let streamStatus = 5005
    static let streamEnd = 6000
    /// The glasses played a reply out: a flag byte, optionally followed by the interaction id.
    static let streamConsumed = 6001
    /// Live-translation 6-channel outward microphone audio on s0.
    static let liveTranslationStreamAudio = 6100
    static let liveTranslationStreamEnd = 6101
    static let liveTranslationStreamHeader = 6102
    /// `{1 seq, 2 inner type, 3 payload}`; each must be acknowledged with `{1 seq}` at 9001.
    static let envelope = 9000
    static let envelopeAck = 9001

    /// Messages the glasses send that need nothing from the phone (init answers, time stretch, TTS buffer config,
    /// MMAI enabled).
    static let ignored: Set<Int> = [1028, 1033, 1036, 1037]
}

/// IDNM message types (Meta's inter-device protobuf envelope `{1 type, 2 payload}`).
enum IdnmType {
    /// `{1 interaction}`.
    static let startOfUserSpeech: Int64 = 1
    /// `{8 interaction}`. It carries no text.
    static let finalTranscription: Int64 = 2
    /// The answer: `{1 interaction, 2 streaming, 5 terminal, 6 {2 expect follow-up}, 7 {1 fulfilment type}}`.
    static let voiceActionResponse: Int64 = 5
    /// `{1 interaction, 2 status}`, either way.
    static let interactionClose: Int64 = 11
    /// "Still working": `{1 "AwaitingResponse", 2 timeout ms, 3 seq}`.
    static let keepAlive: Int64 = 14
    /// The glasses ask the phone to announce an incoming message or timer alert. See `GlassesSpeechRequest`.
    static let glassesRequest: Int64 = 6
}

/// Builders for what ReGlass sends on svc15.
enum AssistantMessages {
    /// The reply stream's Opus profile: 24 kHz mono, 20 ms frames.
    static let replySampleRate = 24_000
    static let replyFrameSamples = 480
    /// Bitrates the glasses' reply decoder accepts; anything else falls back to `defaultReplyBitrate`.
    static let replyBitrates: Set<Int> = [16_000, 24_000, 32_000, 40_000, 48_000]
    static let defaultReplyBitrate = 32_000

    /// Registration of one channel: `{1 session, 2 client, 3 endpoint, 4 2}`. Field 4 is 2 in every registration.
    static func registration(session: String, client: String, endpoint: String) -> [UInt8] {
        Wire.fieldBytes(1, Array(session.utf8)) + Wire.fieldBytes(2, Array(client.utf8))
            + Wire.fieldBytes(3, Array(endpoint.utf8)) + Wire.fieldVarintUnsigned(4, 2)
    }

    /// Declares the seven companion resources in sequence. The glasses need them to play reply audio.
    static func resources() -> [(type: Int, payload: [UInt8])] {
        func id() -> [UInt8] { Wire.fieldBytes(1, Array(newID().utf8)) }
        return [
            (AssistantMessageType.pairedDevice, Wire.fieldBytes(1, Array(sessionString().utf8))),
            (AssistantMessageType.airResourcesUnavailable, id()),
            (AssistantMessageType.liveModeAirResourcesUnavailable, id()),
            (AssistantMessageType.deviceActive, []),
            (AssistantMessageType.numberOfDevicesPaired, Array("1".utf8)),   // a bare string, not protobuf
            (AssistantMessageType.liveModeAirResourcesAvailable, id()),
            (AssistantMessageType.airResourcesAvailable, id()),
        ]
    }

    static func envelopeAck(_ seq: Int64) -> [UInt8] {
        Wire.fieldVarintUnsigned(1, seq)
    }

    static func startOfUserSpeech(_ interaction: String) -> [UInt8] {
        idnm(IdnmType.startOfUserSpeech, Wire.fieldBytes(1, Array(interaction.utf8)))
    }

    static func finalTranscription(_ interaction: String) -> [UInt8] {
        idnm(IdnmType.finalTranscription, Wire.fieldBytes(8, Array(interaction.utf8)))
    }

    static func keepAlive(_ seq: Int64) -> [UInt8] {
        idnm(IdnmType.keepAlive, Wire.fieldBytes(1, Array("AwaitingResponse".utf8))
             + Wire.fieldVarintUnsigned(2, 20_000) + Wire.fieldVarintUnsigned(3, seq))
    }

    /// The answer, after the reply stream ends. Field 2 (streamingBackTts) and field 7 (fulfilment type 1) are the
    /// values of the answer template the glasses accepted; field 5 is written even when 0.
    static func answer(_ interaction: String, expectFollowUp: Bool) -> [UInt8] {
        let terminal: Int64 = expectFollowUp ? 0 : 1
        let body = Wire.fieldBytes(1, Array(interaction.utf8))
            + Wire.fieldVarintUnsigned(2, 1)
            + Wire.fieldVarintUnsigned(5, terminal)
            + Wire.fieldBytes(6, Wire.fieldVarintUnsigned(2, 1 - terminal))
            + Wire.fieldBytes(7, Wire.fieldVarintUnsigned(1, 1))
        return idnm(IdnmType.voiceActionResponse, body)
    }

    /// Closes an interaction with status 1000 (success).
    static func close(_ interaction: String) -> [UInt8] {
        idnm(IdnmType.interactionClose, Wire.fieldBytes(1, Array(interaction.utf8)) + Wire.fieldVarintUnsigned(2, 1000))
    }

    /// The reply stream header: no stream id (the microphone's must never be reused), the interaction, encoding 1
    /// (Opus), interruptible 1, the player in field 19 (1 for every normal reply), and the CELT bitrate in field 20.
    static func replyHeader(_ interaction: String, bitrate: Int, playback: AssistantPlayback = .assistant) -> [UInt8] {
        Wire.fieldBytes(2, Array(interaction.utf8)) + Wire.fieldVarintUnsigned(4, 1) + Wire.fieldVarintUnsigned(7, 1)
            + Wire.fieldVarintUnsigned(19, playback.headerValue) + Wire.fieldVarintUnsigned(20, Int64(bitrate))
    }

    /// One reply audio message: each packet prefixed with its length as a little-endian u32.
    static func replyAudio(_ packets: [[UInt8]]) -> [UInt8] {
        var out = [UInt8]()
        for packet in packets {
            let n = UInt32(packet.count)
            out += [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]
            out += packet
        }
        return out
    }

    static func idnm(_ type: Int64, _ payload: [UInt8]) -> [UInt8] {
        Wire.fieldVarintUnsigned(1, type) + Wire.fieldBytes(2, payload)
    }

    /// A lowercase UUID string, as every id ReGlass makes on svc15.
    static func newID() -> String { UUID().uuidString.lowercased() }

    /// `"<epoch ms>-<uuid>"`.
    static func sessionString() -> String {
        "\(Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)))-\(newID())"
    }
}

extension AssistantPlayback: CustomStringConvertible {
    /// 5002 field 19 (the app's TTS use case: 1 assistant, 2 incoming-message announcement, 4 live translation LST).
    var headerValue: Int64 {
        switch self {
        case .assistant: return 1
        case .messaging: return 2
        case .liveTranslation: return 4
        }
    }

    public var description: String {
        switch self {
        case .assistant: return "assistant player (field 19 = 1)"
        case .messaging: return "messaging player (field 19 = 2)"
        case .liveTranslation: return "live translation player (field 19 = 4)"
        }
    }
}

/// svc72 controls the glasses' outward microphone capture for live translation (16 kHz, 6 channels, mode `0x305`).
enum LiveTranslationMessages {
    static let service = DataXService.liveTranslation
    static let inviteToJoin = 2
    static let translationAck = 3
    static let stoppingFromFrame = 4
    static let endFromFrame = 5
    static let ttsStarted = 6
    static let ttsEnded = 7
    static let scopeCreatedHello = 8
    static let stopRequest = 9

    /// svc72 message 2 starts capture. Tag 1 is set to 1, tags 2 and 3 carry the wearer and other speaker languages
    /// (up to 15 bytes each), and tag 6 carries the request ID (up to 63 bytes).
    static func inviteToJoin(selfLang: String, otherLang: String, requestID: String) -> [UInt8] {
        let selfBytes = Array(selfLang.prefix(15).utf8)
        let otherBytes = Array(otherLang.prefix(15).utf8)
        let reqBytes = Array(requestID.prefix(63).utf8)
        return Wire.fieldVarintUnsigned(1, 1)
            + Wire.fieldBytes(2, selfBytes)
            + Wire.fieldBytes(3, otherBytes)
            + Wire.fieldBytes(6, reqBytes)
    }

    /// svc72 message 9 stops capture. Tags 1 and 2 carry the request and session IDs (up to 63 bytes each), and
    /// tag 3 is set to 1.
    static func stopRequest(requestID: String, sessionID: String) -> [UInt8] {
        let reqBytes = Array(requestID.prefix(63).utf8)
        let sessBytes = Array(sessionID.prefix(63).utf8)
        return Wire.fieldBytes(1, reqBytes)
            + Wire.fieldBytes(2, sessBytes)
            + Wire.fieldVarintUnsigned(3, 1)
    }

    /// svc72 message 3 acknowledges the request. Tags 1, 2 and 3 carry an optional session ID, the request ID
    /// and whether the glasses accepted it.
    static func decodeAck(_ payload: [UInt8]) -> (requestID: String, accepted: Bool)? {
        guard let fields = try? Wire.parse(payload) else { return nil }
        let req = String(decoding: fields.bytes(2), as: UTF8.self)
        let ack = fields.varint(3) != 0
        return (req, ack)
    }

    /// Reads the session ID the glasses add at tag 4 when they echo the start request (svc72 message 2).
    static func decodeInviteSessionID(_ payload: [UInt8]) -> String? {
        guard let fields = try? Wire.parse(payload), fields.has(4) else { return nil }
        let id = String(decoding: fields.bytes(4), as: UTF8.self)
        return id.isEmpty ? nil : id
    }

    /// Reads the glasses' session ID at tag 1 of the s0 capture header (message 6102).
    static func decodeCaptureStartSessionID(_ payload: [UInt8]) -> String? {
        guard let fields = try? Wire.parse(payload), fields.has(1) else { return nil }
        let id = String(decoding: fields.bytes(1), as: UTF8.self)
        return id.isEmpty ? nil : id
    }
}

/// svc46 carries phone message notifications that the glasses announce themselves.
/// Nothing is sent on it; its statuses are logged.
enum NotificationMessages {
    static let service = 46
}

/// The request names the glasses' firmware gives its asks for speech. Log-safe: fixed event names, never content.
enum GlassesRequestName {
    static let incomingMessage = "incoming_message"
    static let tarAlert = "tar_alert"

    /// Which request `payload` carries, by its event name appearing anywhere in it.
    static func find(in payload: [UInt8]) -> String? {
        for name in [incomingMessage, tarAlert] where payload.contains(subsequence: Array(name.utf8)) { return name }
        return nil
    }
}

extension Array where Element == UInt8 {
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        for start in 0...(count - needle.count) where self[start] == needle[0] {
            if Array(self[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

// MARK: What the glasses send

/// A 9000 envelope.
struct AssistantEnvelope {
    let seq: Int64?
    let innerType: Int
    let payload: [UInt8]

    static func decode(_ payload: [UInt8]) throws -> AssistantEnvelope {
        let fields = try Wire.parse(payload)
        return AssistantEnvelope(seq: fields.has(1) ? fields.varint(1) : nil,
                                 innerType: Int(Int32(truncatingIfNeeded: fields.varint(2))),
                                 payload: fields.bytes(3))
    }
}

/// 1040 StartSession. The interaction is field 4, or the session when that is empty.
struct StartSession {
    let session: String
    let interaction: String

    static func decode(_ payload: [UInt8]) throws -> StartSession? {
        let fields = try Wire.parse(payload)
        let session = String(decoding: fields.bytes(1), as: UTF8.self)
        let supplied = String(decoding: fields.bytes(4), as: UTF8.self)
        guard !session.isEmpty else { return nil }
        return StartSession(session: session, interaction: supplied.isEmpty ? session : supplied)
    }
}

/// The glasses' 5002 microphone header: `{1 stream, 2 interaction, 4 encoding, 6 session, 9 skip start, 12 rate}`.
struct MicrophoneHeader {
    let stream: String
    let interaction: String
    let session: String
    let encoding: Int64
    let sampleRate: Int64

    static func decode(_ payload: [UInt8]) throws -> MicrophoneHeader {
        let fields = try Wire.parse(payload)
        return MicrophoneHeader(stream: String(decoding: fields.bytes(1), as: UTF8.self),
                                interaction: String(decoding: fields.bytes(2), as: UTF8.self),
                                session: String(decoding: fields.bytes(6), as: UTF8.self),
                                encoding: fields.varint(4), sampleRate: fields.varint(12))
    }
}

/// An IDNM message inside a 1010.
struct IdnmMessage {
    let type: Int64
    let payload: [UInt8]

    static func decode(_ payload: [UInt8]) throws -> IdnmMessage? {
        let fields = try Wire.parse(payload)
        guard fields.has(1), fields.has(2) else { return nil }
        return IdnmMessage(type: fields.varint(1), payload: fields.bytes(2))
    }

    /// Field 1 of an interaction close, or "".
    func closedInteraction() -> String {
        guard let fields = try? Wire.parse(payload) else { return "" }
        return String(decoding: fields.bytes(1), as: UTF8.self)
    }
}

/// 6001: which interaction the glasses finished playing, when they say.
func consumedInteraction(_ payload: [UInt8]) -> String {
    payload.count > 1 ? String(decoding: payload.dropFirst(), as: UTF8.self) : ""
}

/// 5005 `<stream>_<interaction>_<pcm bytes>_<ms>`, as numbers only; nil when it does not read so.
func replyStatus(_ payload: [UInt8]) -> (pcmBytes: Int64, milliseconds: Int64)? {
    let parts = String(decoding: payload, as: UTF8.self).split(separator: "_", omittingEmptySubsequences: false)
    guard parts.count >= 4, let ms = Int64(parts[parts.count - 1]), let pcm = Int64(parts[parts.count - 2]) else { return nil }
    return (pcm, ms)
}

/// Puts 1002/1003 segmented messages back together, by id.
struct SegmentAssembler {
    private var pending: [String: (type: Int, size: Int, bytes: [UInt8])] = [:]

    enum Outcome {
        case incomplete
        case whole(type: Int, payload: [UInt8])
        /// A piece of a message never announced, or a whole one of the wrong size (log-safe reason).
        case dropped(String)
    }

    mutating func add(_ type: Int, _ payload: [UInt8]) throws -> Outcome {
        let fields = try Wire.parse(payload)
        if type == AssistantMessageType.segmentHeader {
            let id = String(decoding: fields.bytes(3), as: UTF8.self)
            // Bounded: a peer that never finishes its messages can't grow this without limit.
            if pending.count >= 8 { pending.removeAll() }
            pending[id] = (Int(Int32(truncatingIfNeeded: fields.varint(1))), Int(Int32(truncatingIfNeeded: fields.varint(2))), [])
            return .incomplete
        }
        let id = String(decoding: fields.bytes(2), as: UTF8.self)
        guard var segment = pending[id] else { return .dropped("a piece of an unknown segmented message") }
        segment.bytes += fields.bytes(1)
        guard fields.varint(3) != 0 else {
            pending[id] = segment
            return .incomplete
        }
        pending[id] = nil
        guard segment.bytes.count == segment.size else {
            return .dropped("segmented message came to \(segment.bytes.count) of \(segment.size) bytes")
        }
        return .whole(type: segment.type, payload: segment.bytes)
    }
}
