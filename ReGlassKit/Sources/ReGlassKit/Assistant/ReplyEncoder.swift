import Foundation
import ReGlassOpus

/// Reply audio to what the glasses play: 24 kHz mono PCM in 20 ms frames to libopus CELT-only CBR packets, exactly
/// `bitrate / 400` bytes each (80 at 32 kbps). Each packet is checked before it may be sent.
final class ReplyEncoder {
    let bitrate: Int
    /// The encoder's delay in samples: this much silence is flushed after the last sample so the end isn't cut.
    let lookahead: Int
    private let encoder: UnsafeMutableRawPointer
    private let packetBytes: Int

    init(bitrate: Int) throws {
        var error: Int32 = 0
        var delay: Int32 = 0
        guard let made = reglass_opus_reply_encoder_create(Int32(AssistantMessages.replySampleRate), Int32(bitrate),
                                                         &error, &delay) else {
            kitLog("assistant", "the reply encoder could not start (\(error))")
            throw ReGlassError.protocolFailure("the reply encoder could not start")
        }
        encoder = made
        self.bitrate = bitrate
        lookahead = Int(max(0, delay))
        packetBytes = bitrate / 400
    }

    deinit { reglass_opus_encoder_destroy(encoder) }

    /// One 20 ms frame (480 samples) to one packet.
    func encode(_ frame: [Int16]) throws -> [UInt8] {
        precondition(frame.count == AssistantMessages.replyFrameSamples, "a reply frame is 480 samples")
        var packet = [UInt8](repeating: 0, count: packetBytes)
        let written = frame.withUnsafeBufferPointer { pcm in
            packet.withUnsafeMutableBufferPointer { out in
                reglass_opus_encode(encoder, pcm.baseAddress, Int32(frame.count), out.baseAddress, Int32(packetBytes))
            }
        }
        // CBR at this size, a CELT configuration (TOC config 16 or more), mono, 20 ms of audio.
        guard Int(written) == packetBytes, let toc = packet.first, toc >> 3 >= 16, toc & 0x04 == 0,
              opusDurationMicros(packet) == 20_000 else {
            throw ReGlassError.protocolFailure("the reply encoder made an unusable packet")
        }
        return packet
    }
}

/// How long an Opus packet plays, from its TOC byte (RFC 6716, 3.1).
func opusDurationMicros(_ packet: [UInt8]) -> Int {
    guard let first = packet.first else { return 0 }
    let toc = Int(first)
    let config = toc >> 3
    let frameMicros: Int
    if config < 12 {
        frameMicros = [10_000, 20_000, 40_000, 60_000][config & 3]
    } else if config < 16 {
        frameMicros = [10_000, 20_000][config & 1]
    } else {
        frameMicros = [2_500, 5_000, 10_000, 20_000][config & 3]
    }
    let frames: Int
    switch toc & 3 {
    case 0: frames = 1
    case 1, 2: frames = 2
    default: frames = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
    }
    return frameMicros * frames
}

/// Reads the app's reply stream into `buffer` until it ends, throws, or the task is cancelled.
func startFeeding(_ audio: AsyncThrowingStream<[Int16], Error>, into buffer: ReplyBuffer) -> Task<Void, Never> {
    Task {
        do {
            for try await chunk in audio { buffer.append(chunk) }
            buffer.finish(nil)
        } catch {
            buffer.finish(error)
        }
    }
}

/// PCM the voice has produced and the pacer hasn't taken yet. Written by the task reading the app's stream, read
/// by the pacer. `@unchecked Sendable`: all state is behind `Locked`.
final class ReplyBuffer: @unchecked Sendable {
    enum Frame {
        case audio([Int16])
        /// The voice is behind: send silence to hold real time, keep what is buffered. The pacer caps a continuous
        /// run (`AssistantService.maxReplyGap`).
        case silence
        /// The voice finished and everything, the encoder flush included, has been taken.
        case end
    }

    private struct State {
        var samples: [Int16] = []
        var head = 0
        var received = 0
        var finished = false
        var flushed = false
        var failure: Error?
    }

    private let state = Locked(State())
    /// Keep every sample, so the same audio can be sent again (a push's fallback to the other player).
    private let keepsAll: Bool

    init(keepsAll: Bool = false) {
        self.keepsAll = keepsAll
    }

    /// A finished buffer holding everything this one received, for a second attempt. Nil unless built with
    /// `keepsAll` and finished with audio.
    func replay() -> ReplyBuffer? {
        guard keepsAll else { return nil }
        let samples: [Int16]? = state.withLock { state in
            guard state.finished, state.received > 0 else { return nil }
            return Array(state.samples[0..<state.received])
        }
        guard let samples else { return nil }
        let copy = ReplyBuffer()
        copy.append(samples)
        copy.finish(nil)
        return copy
    }

    var isFinished: Bool { state.withLock { $0.finished } }

    func append(_ chunk: [Int16]) {
        guard !chunk.isEmpty else { return }
        state.withLock { state in
            guard !state.finished else { return }
            state.samples += chunk
            state.received += chunk.count
        }
    }

    /// The voice ended, with `failure` when its stream threw.
    func finish(_ failure: Error?) {
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            state.failure = failure
        }
    }

    /// Enough is buffered to start (or the voice already finished).
    func isReady(preroll: Int) -> Bool {
        state.withLock { $0.finished || $0.samples.count - $0.head >= preroll }
    }

    var received: Int { state.withLock { $0.received } }
    var failure: Error? { state.withLock { $0.failure } }

    /// The next frame of `size` samples. After the voice finishes, `flush` zero samples follow the last one and the
    /// final frame is padded with zeros.
    func nextFrame(size: Int, flush: Int) -> Frame {
        state.withLock { state in
            if state.finished, !state.flushed, state.received > 0 {
                state.samples += [Int16](repeating: 0, count: flush)
                state.flushed = true
            }
            let available = state.samples.count - state.head
            if available >= size {
                defer { state.head += size; compact(&state) }
                return .audio(Array(state.samples[state.head..<(state.head + size)]))
            }
            guard state.finished else { return .silence }
            guard available > 0 else { return .end }
            var frame = Array(state.samples[state.head...])
            frame += [Int16](repeating: 0, count: size - available)
            state.head = state.samples.count
            compact(&state)
            return .audio(frame)
        }
    }

    private func compact(_ state: inout State) {
        if !keepsAll, state.head >= 48_000 {
            state.samples.removeFirst(state.head)
            state.head = 0
        }
    }
}
