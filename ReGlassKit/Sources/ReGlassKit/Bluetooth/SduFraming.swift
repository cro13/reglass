import Foundation

/// How the glasses' L2CAP SDUs are delimited on the stream. Each starts with one of two headers, told apart by its
/// leading byte:
/// - DataX (bit 0x80 set): two bytes of flags and a 14-bit length, two of channel id; 4 + length bytes in all.
/// - AirShield data (top bits `01`): the frame byte, an 8-byte tag, the block count less one; 10 + 16 × count bytes.
/// Any other leading byte can't be framed.
enum SduFraming {
    static let minimumHead = 2
    static let dataXHeader = 4
    static let airShieldHeader = 10
    static let aesBlock = 16

    /// The total length of the SDU starting at `head`, or nil until enough of it has arrived to say.
    static func length(of head: ArraySlice<UInt8>) throws -> Int? {
        guard head.count >= minimumHead else { return nil }
        let first = head[head.startIndex]
        if first & 0x80 != 0 {
            return dataXHeader + (Int(first & 0x3F) << 8 | Int(head[head.startIndex + 1]))
        }
        if first & 0xC0 == 0x40 {
            guard head.count >= airShieldHeader else { return nil }
            return airShieldHeader + aesBlock * (Int(head[head.startIndex + 9]) + 1)
        }
        throw ReGlassError.protocolFailure(String(format: "unframeable leading byte 0x%02x", first))
    }
}

/// Cuts a byte stream into whole SDUs.
struct SduReassembler {
    private var buffer: [UInt8] = []
    private var start = 0

    /// Adds bytes from the stream and hands over every SDU they complete, in order. At a leading byte that fits
    /// neither header it throws, after handing over the SDUs before it: the stream can't be framed past that point.
    mutating func append(_ bytes: ArraySlice<UInt8>, deliver: ([UInt8]) -> Void) throws {
        buffer.append(contentsOf: bytes)
        defer { compact() }
        while let length = try SduFraming.length(of: buffer[start...]), buffer.count - start >= length {
            deliver(Array(buffer[start..<(start + length)]))
            start += length
        }
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 1 << 16 {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
