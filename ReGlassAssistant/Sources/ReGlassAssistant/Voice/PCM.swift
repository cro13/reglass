@preconcurrency import AVFoundation
import Foundation

/// ReGlass's audio formats: replies are 24 kHz mono Int16 PCM (what ElevenLabs sends as `pcm_24000` and what the
/// glasses' reply encoder takes); the glasses' microphone arrives as 16 kHz mono Int16.
public enum PCM {
    public static let replyRate: Double = 24_000
    public static let micRate: Double = 16_000

    /// 24 kHz mono Int16, interleaved.
    public static let replyFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: replyRate, channels: 1,
                                                  interleaved: true)!
    /// 16 kHz mono Int16, interleaved.
    public static let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: micRate, channels: 1,
                                                interleaved: true)!

    /// Seconds of audio in `samples` at the reply rate.
    public static func replySeconds(_ samples: Int) -> TimeInterval { Double(samples) / replyRate }

    /// Wraps Int16 samples in a buffer of `format` (which must be mono Int16).
    static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// The samples of a mono Int16 buffer.
    static func samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// Little-endian Int16 bytes to samples, carrying an odd trailing byte over to the next chunk.
struct PCMByteDecoder {
    private var carry: UInt8?

    mutating func decode(_ data: Data) -> [Int16] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let carry { bytes.append(carry) }
        bytes.append(contentsOf: data)
        if bytes.count % 2 == 1 {
            carry = bytes.removeLast()
        } else {
            carry = nil
        }
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            samples[i] = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
        }
        return samples
    }
}

/// Resamples and reformats a stream of buffers into mono Int16 at `outputRate`, keeping the resampler's state
/// between buffers so there are no clicks at the seams.
final class StreamingConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputRate: Double) {
        output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true)!
    }

    init(output: AVAudioFormat) {
        self.output = output
    }

    /// Converts one buffer; returns what's ready (a resampler holds a few samples back until `flush`).
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return out.frameLength > 0 ? out : nil
    }

    /// The samples still held inside the resampler.
    func flush() -> AVAudioPCMBuffer? {
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024) else { return nil }
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return out.frameLength > 0 ? out : nil
    }
}
