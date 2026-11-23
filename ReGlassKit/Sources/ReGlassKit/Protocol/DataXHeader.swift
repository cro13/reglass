import Foundation

/// A malformed DataX header.
enum HeaderError: Error, Equatable {
    case tooShort(Int)
    case messageTooLarge(Int)
}

/// Flags carried in the DataX message header.
struct HeaderFlags: Equatable, Hashable {
    var valid = true
    var complete = true
    var hasExtension = false
    var setService = false
    var setType = false
    var hasError = false
    var isClosed = false
    var hasQos = false
}

/// A parsed DataX message header.
struct MessageInfo: Equatable, Hashable {
    var flags: HeaderFlags
    /// The 14-bit payload length, which includes the extension tags.
    var length: Int
    /// The 16-bit channel id; its high bit says who opened the channel.
    var channelId: Int
    var serviceId = 0
    var messageType = 0
    var errorId = 0
    /// 4 plus four per extension tag.
    var headerLen = 4

    /// Bytes this message occupies on the wire. It is `4 + length`, never `headerLen + length`.
    var wireTotal: Int { 4 + length }
}

/// DataX 4-byte fixed header plus extension-tag codec.
enum DataXHeader {

    private static let tagServiceId = 1
    private static let tagMessageType = 2
    private static let tagErrorId = 3
    private static let tagMessageTypeClosed = 4
    private static let tagQos = 5

    static func parse(_ buf: [UInt8]) throws -> MessageInfo {
        guard buf.count >= 4 else { throw HeaderError.tooShort(buf.count) }

        let b0 = Int(buf[0])
        let hasExtension = (b0 >> 7) & 1
        let payloadLen = ((b0 & 0x3F) << 8) | Int(buf[1])
        let channelId = (Int(buf[2]) << 8) | Int(buf[3])

        var serviceId = 0
        var messageType = 0
        var errorId = 0

        var valid = true
        let complete = (buf.count - 4) >= payloadLen
        var setService = false
        var setType = false
        var hasError = false
        var isClosed = false
        var hasQos = false
        var headerLen = 4

        if hasExtension == 1 {
            var offset = 4
            let available = min(buf.count, 4 + payloadLen)
            var sawLastTag = false
            while offset + 4 <= available {
                let tagByte = Int(buf[offset])
                let d1 = Int(buf[offset + 1])
                let value16 = (Int(buf[offset + 2]) << 8) | Int(buf[offset + 3])
                let continuation = (tagByte >> 7) & 1
                let tagId = tagByte & 0x7F

                switch tagId {
                case tagServiceId:
                    serviceId = value16
                    setService = true
                    setType = true
                    if value16 == 0 { isClosed = true }
                case tagMessageType:
                    messageType = value16
                    setType = true
                case tagErrorId:
                    errorId = value16
                    hasError = true
                case tagMessageTypeClosed:
                    messageType = value16
                    isClosed = true
                case tagQos:
                    _ = d1
                    hasQos = true
                default:
                    break   // unknown tag, skip
                }

                headerLen += 4
                offset += 4
                if continuation == 0 { sawLastTag = true; break }
            }
            if !sawLastTag { valid = false }   // ran out of data mid-extension
        }

        return MessageInfo(
            flags: HeaderFlags(
                valid: valid, complete: complete, hasExtension: hasExtension == 1,
                setService: setService, setType: setType, hasError: hasError,
                isClosed: isClosed, hasQos: hasQos
            ),
            length: payloadLen, channelId: channelId,
            serviceId: serviceId, messageType: messageType, errorId: errorId, headerLen: headerLen
        )
    }

    /// Serialise a DataX header: the fixed 4 bytes plus extension tags, continuation bit on all but the last.
    static func build(
        channelId: Int,
        dataLen: Int,
        serviceId: Int? = nil,
        messageType: Int? = nil,
        errorId: Int? = nil
    ) throws -> [UInt8] {
        var tags: [(tagId: Int, value16: Int)] = []
        if let serviceId { tags.append((tagServiceId, serviceId & 0xFFFF)) }
        if let messageType { tags.append((tagMessageType, messageType & 0xFFFF)) }
        if let errorId { tags.append((tagErrorId, errorId & 0xFFFF)) }

        let payloadLen = tags.count * 4 + dataLen
        guard payloadLen <= dataXMaxMessage else { throw HeaderError.messageTooLarge(payloadLen) }

        let hasExtension = tags.isEmpty ? 0 : 1
        var out = [UInt8]()
        out.reserveCapacity(4 + tags.count * 4)
        out.append(UInt8(truncatingIfNeeded: (hasExtension << 7) | ((payloadLen >> 8) & 0x3F)))
        out.append(UInt8(truncatingIfNeeded: payloadLen & 0xFF))
        out.append(UInt8(truncatingIfNeeded: (channelId >> 8) & 0xFF))
        out.append(UInt8(truncatingIfNeeded: channelId & 0xFF))

        for (i, tag) in tags.enumerated() {
            let continuation = i < tags.count - 1 ? 1 : 0
            out.append(UInt8(truncatingIfNeeded: (continuation << 7) | (tag.tagId & 0x7F)))
            out.append(0)
            out.append(UInt8(truncatingIfNeeded: (tag.value16 >> 8) & 0xFF))
            out.append(UInt8(truncatingIfNeeded: tag.value16 & 0xFF))
        }
        return out
    }
}
