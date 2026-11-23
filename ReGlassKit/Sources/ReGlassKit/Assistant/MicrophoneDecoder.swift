import Foundation
import ReGlassOpus

/// The glasses' microphone (5003 chunks of Opus, about 16 kbps) to 16 kHz mono Int16 PCM.
///
/// Decodes with libopus straight at 16 kHz, its native rate for wideband speech, so there is no resampling at all.
final class MicrophoneDecoder {
    /// What one chunk held.
    struct Chunk {
        var samples: [Int16] = []
        var packets = 0
        /// Set when the chunk's framing did not parse; the packets before the fault still decode.
        var fault: String?
    }

    static let sampleRate: Int32 = 16_000
    /// 120 ms at 16 kHz, the longest an Opus packet can play.
    private static let maxPacketSamples = 1_920

    private let decoder: UnsafeMutableRawPointer?
    private var output = [Int16](repeating: 0, count: maxPacketSamples)
    private(set) var failedPackets = 0

    init() {
        var error: Int32 = 0
        decoder = reglass_opus_decoder_create(Self.sampleRate, &error)
        if decoder == nil { kitLog("assistant", "the microphone decoder could not start (\(error))") }
    }

    deinit {
        reglass_opus_decoder_destroy(decoder)
    }

    func decode(_ chunk: [UInt8]) -> Chunk {
        var result = Chunk()
        let framing = MicrophoneFraming.packets(chunk)
        result.fault = framing.fault
        for packet in framing.packets {
            result.packets += 1
            guard let decoder, !packet.isEmpty else { continue }
            let count = packet.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { pcm in
                    reglass_opus_decode(decoder, input.baseAddress, Int32(packet.count),
                                      pcm.baseAddress, Int32(Self.maxPacketSamples))
                }
            }
            if count > 0 { result.samples += output[0..<Int(count)] } else { failedPackets += 1 }
        }
        return result
    }
}

/// The three ways the glasses frame Opus packets in a 5003 chunk (all three seen on hardware).
enum MicrophoneFraming {
    static func packets(_ chunk: [UInt8]) -> (packets: [[UInt8]], fault: String?) {
        switch batched(chunk) {
        case .notBatched: break
        case .invalid(let why): return ([], "batched: " + why)
        case .packets(let packets): return (packets, nil)
        }
        var reader = ByteReader(chunk)
        // A little-endian length read big-endian is far larger than the chunk, so this tells the two apart.
        if reader.remaining >= 5, (1...(reader.remaining - 4)).contains(Int(reader.uint32BE(at: 0))) {
            return lengthPrefixed(&reader)
        }
        return timestamped(&reader)
    }

    private enum Batch {
        case notBatched
        case invalid(String)
        case packets([[UInt8]])
    }

    /// Firmware 1082194281: records of `[u32 LE length][u32 LE ms][01 00 00 00 00]` then repeated
    /// `[u32 LE packet length][Opus]` (145-byte chunks of three 40-byte packets, 60 ms). The whole chunk is checked
    /// before any of it is used.
    private static func batched(_ chunk: [UInt8]) -> Batch {
        let prefix: [UInt8] = [1, 0, 0, 0, 0]
        guard chunk.count >= 13, Array(chunk[8..<13]) == prefix else { return .notBatched }
        var reader = ByteReader(chunk)
        var packets: [[UInt8]] = []
        while reader.remaining > 0 {
            let start = reader.position
            guard reader.remaining >= 18 else { return .invalid("truncated record header") }
            let length = Int(reader.uint32LE())
            guard length >= 14, length <= reader.remaining else { return .invalid("record length \(length)") }
            let end = start + 4 + length
            _ = reader.uint32LE()   // the glasses' audio clock, ms
            guard reader.bytes(5) == prefix else { return .invalid("unknown record prefix") }
            while reader.position < end {
                guard end - reader.position >= 5 else { return .invalid("truncated packet length") }
                let n = Int(reader.uint32LE())
                guard n > 0, n <= end - reader.position else { return .invalid("packet length \(n)") }
                packets.append(reader.bytes(n))
            }
        }
        return packets.isEmpty ? .invalid("empty batch") : .packets(packets)
    }

    /// `[u32 BE length][Opus]` repeated, no time.
    private static func lengthPrefixed(_ reader: inout ByteReader) -> (packets: [[UInt8]], fault: String?) {
        var packets: [[UInt8]] = []
        while reader.remaining >= 5 {
            let n = Int(reader.uint32BE())
            guard n > 0, n <= reader.remaining else { return (packets, "length-prefixed: packet length \(n)") }
            packets.append(reader.bytes(n))
        }
        return (packets, reader.remaining == 0 ? nil : "length-prefixed: \(reader.remaining) trailing bytes")
    }

    /// `[u32 LE length][u32 LE ms][u32 BE Opus length][u32 BE range][Opus]` repeated.
    private static func timestamped(_ reader: inout ByteReader) -> (packets: [[UInt8]], fault: String?) {
        var packets: [[UInt8]] = []
        while reader.remaining >= 16 {
            _ = reader.uint32LE()
            _ = reader.uint32LE()
            let n = Int(reader.uint32BE())
            _ = reader.uint32BE()
            guard n > 0, n <= reader.remaining else { return (packets, "timestamped: packet length \(n)") }
            packets.append(reader.bytes(n))
        }
        return (packets, reader.remaining == 0 ? nil : "timestamped: \(reader.remaining) trailing bytes")
    }
}

/// Sequential reads over bytes, for the microphone framings.
struct ByteReader {
    private let data: [UInt8]
    private(set) var position = 0

    init(_ data: [UInt8]) { self.data = data }

    var remaining: Int { data.count - position }

    func uint32BE(at i: Int) -> UInt32 {
        UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    mutating func uint32BE() -> UInt32 {
        defer { position += 4 }
        return uint32BE(at: position)
    }

    mutating func uint32LE() -> UInt32 {
        defer { position += 4 }
        let i = position
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    mutating func bytes(_ n: Int) -> [UInt8] {
        defer { position += n }
        return Array(data[position..<(position + n)])
    }
}

/// Decodes outward live-translation microphone audio from s0 message 6100. The glasses send 16 kHz, 6-channel
/// audio in mode `0x305` as 128 kbps self-delimiting multistream Opus (RFC 6716).
final class LiveTranslationMicDecoder {
    static let sampleRate: Int32 = 16_000
    static let channelCount: Int = 6
    private static let maxFrameSamples: Int32 = 960
    /// The first 24 bytes of the 320-byte frame the glasses send while the microphones are muted.
    private static let mutedReplacementPrefix: [UInt8] = [
        0xB8, 0x02, 0xFF, 0xFE, 0xB8, 0x02, 0xFF, 0xFE, 0xB8, 0x02, 0xFF, 0xFE,
        0xB8, 0x02, 0xFF, 0xFE, 0xB8, 0x02, 0xFF, 0xFE, 0xB8, 0xFF, 0xFE, 0x00,
    ]

    struct Chunk {
        /// 6 channels of 16 kHz PCM (`channels[0..<6]`, each typically 320 samples per 20 ms packet).
        let channels: [[Int16]]
        /// True when the packet matches the glasses' muted replacement frame.
        let isMutedReplacement: Bool
        let fault: String?
    }

    private let msDecoder: UnsafeMutableRawPointer?
    private let monoDecoder: UnsafeMutableRawPointer?
    private var carry = [UInt8]()
    private var interleaved = [Int16](repeating: 0, count: Int(maxFrameSamples) * channelCount)

    init() {
        var msErr: Int32 = 0
        msDecoder = reglass_opus_multistream_decoder_create(Self.sampleRate, Int32(Self.channelCount), &msErr)
        var monoErr: Int32 = 0
        monoDecoder = reglass_opus_decoder_create(Self.sampleRate, &monoErr)
    }

    deinit {
        reglass_opus_multistream_decoder_destroy(msDecoder)
        reglass_opus_decoder_destroy(monoDecoder)
    }

    func decode(_ chunk: [UInt8]) -> Chunk {
        guard let msDecoder else { return Chunk(channels: [], isMutedReplacement: false, fault: "multistream Opus decoder did not open") }
        carry += chunk
        var channels = Array(repeating: [Int16](), count: Self.channelCount)
        var isMuted = false
        var fault: String?
        var pos = 0

        while carry.count - pos >= 4 {
            let b0 = UInt32(carry[pos])
            let b1 = UInt32(carry[pos + 1])
            let b2 = UInt32(carry[pos + 2])
            let b3 = UInt32(carry[pos + 3])
            // Frames start with a four-byte big-endian length, for example 00 00 01 40 for 320 bytes.
            let beLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            let leLen = Int(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
            let length: Int
            if (1...512).contains(beLen) {
                length = beLen
            } else if (1...512).contains(leLen) {
                length = leLen
            } else {
                carry.removeAll()
                fault = "frame length \(beLen) bytes (BE) / \(leLen) bytes (LE) is out of bounds"
                break
            }
            guard carry.count - pos - 4 >= length else { break }
            pos += 4
            let packet = Array(carry[pos..<(pos + length)])
            pos += length

            if packet.count >= Self.mutedReplacementPrefix.count,
               Array(packet.prefix(Self.mutedReplacementPrefix.count)) == Self.mutedReplacementPrefix {
                isMuted = true
            }

            let count = packet.withUnsafeBufferPointer { ptr in
                reglass_opus_multistream_decode(msDecoder, ptr.baseAddress, Int32(packet.count),
                                              &interleaved, Self.maxFrameSamples)
            }
            if count > 0 {
                let frameCount = Int(count)
                for c in 0..<Self.channelCount {
                    channels[c].reserveCapacity(channels[c].count + frameCount)
                }
                for f in 0..<frameCount {
                    let base = f * Self.channelCount
                    for c in 0..<Self.channelCount {
                        channels[c].append(interleaved[base + c])
                    }
                }
            } else if let monoDecoder {
                // Fallback if a single-stream packet ever arrives on 6100: its one channel is copied into all six.
                var mono = [Int16](repeating: 0, count: Int(Self.maxFrameSamples))
                let monoCount = packet.withUnsafeBufferPointer { ptr in
                    reglass_opus_decode(monoDecoder, ptr.baseAddress, Int32(packet.count), &mono, Self.maxFrameSamples)
                }
                if monoCount > 0 {
                    let slice = Array(mono.prefix(Int(monoCount)))
                    for c in 0..<Self.channelCount { channels[c].append(contentsOf: slice) }
                } else if fault == nil {
                    fault = "libopus multistream error \(count)"
                }
            } else if fault == nil {
                fault = "libopus multistream error \(count)"
            }
        }
        if pos > 0 { carry.removeFirst(pos) }
        return Chunk(channels: channels[0].isEmpty ? [] : channels, isMutedReplacement: isMuted, fault: fault)
    }
}
