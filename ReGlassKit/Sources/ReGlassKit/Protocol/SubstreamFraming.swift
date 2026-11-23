import Foundation

/// AirShield substream frame type: the top two bits of the one-byte stream header
/// `[2-bit type | 6-bit stream-id]`.
enum FrameType {
    /// Encrypted application data.
    static let data = 0x40
    /// Cleartext stream control (e.g. stream 0 LOST). The handshake is bare DataX, not this.
    static let command = 0x80
}

/// A malformed substream frame.
enum FramingError: Error, Equatable {
    case empty
    case streamIdOutOfRange(Int)
}

/// One unpacked substream frame.
struct Frame: Equatable {
    let type: Int
    let streamId: Int
    let body: [UInt8]
}

/// AirShield substream framing: the one-byte outer header on each CoC frame.
enum SubstreamFraming {

    static let streamMask = 0x3F
    static let typeMask = 0xC0

    static func pack(_ frameType: Int, _ streamId: Int, _ body: [UInt8]) throws -> [UInt8] {
        guard streamId >= 0 && streamId <= streamMask else { throw FramingError.streamIdOutOfRange(streamId) }
        return [UInt8(truncatingIfNeeded: (frameType & typeMask) | (streamId & streamMask))] + body
    }

    static func unpack(_ data: [UInt8]) throws -> Frame {
        guard let header = data.first else { throw FramingError.empty }
        return Frame(type: Int(header) & typeMask, streamId: Int(header) & streamMask, body: Array(data[1...]))
    }
}
