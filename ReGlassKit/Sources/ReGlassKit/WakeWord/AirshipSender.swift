import Foundation

/// Sends one file over Airship (svc20) to the Audio MCU's OTA receiver. A pure state machine: the owner moves its
/// frames and hands it the receiver's replies; it never touches the link.
///
/// offer → cursor → data (1024-byte chunks, a silent CHECK cursor every 64 KiB) → COMPLETE → the receiver's DROP →
/// REMOVED, which releases the file to the OTA application. The receiver says nothing to a CHECK that matches; it
/// only answers with a correction cursor. DROP is a transport acknowledgement, not installation.
struct AirshipSender {
    struct Frame: Equatable {
        let type: Int
        let payload: [UInt8]
    }

    enum State: Equatable {
        case initial, awaitingCursor, streaming, awaitingDrop, finishing, delivered, failed
    }

    private(set) var state = State.initial
    /// Bytes handed out so far. A sender cursor, not a receiver acknowledgement.
    private(set) var sent = 0
    let size: Int
    let uuid: [UInt8]
    private let data: [UInt8]
    private let filename: String
    private var checkedAt = 0
    private var rewinds = 0
    private var responses = 0
    private var runningAdler: UInt32 = 1
    private var withdrawn = false

    init(data: [UInt8], uuid: [UInt8], filename: String) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024, uuid.count == 16,
              ResourceOta.filenames.contains(filename) || filename == ResourceOta.bootPlaceholderFilename else {
            throw WakeWordFault.malformed("invalid file for transfer")
        }
        self.data = data
        self.uuid = uuid
        self.filename = filename
        size = data.count
    }

    /// The offer `{1: uuid, 2: size, 3: "ota", 4: filename}`.
    mutating func offer() throws -> Frame {
        guard state == .initial else { throw failure("the file was already offered") }
        state = .awaitingCursor
        return Frame(type: AirshipMessageType.offer,
                     payload: Wire.fieldBytes(1, uuid) + (try Wire.fieldVarint(2, Int64(size)))
                        + Wire.fieldBytes(3, Array("ota".utf8)) + Wire.fieldBytes(4, Array(filename.utf8)))
    }

    /// At most one frame to send now, or nil while a reply is awaited. Keep calling until `delivered`.
    mutating func next() throws -> Frame? {
        if state == .finishing {
            // The receiver tells its OTA application the file is complete when REMOVED releases it after DROP.
            withdrawn = true
            state = .delivered
            return Frame(type: AirshipMessageType.removed, payload: Wire.fieldBytes(1, uuid))
        }
        guard state == .streaming else { return nil }
        if sent == size {
            state = .awaitingDrop
            return Frame(type: AirshipMessageType.complete, payload: try cursor(sent, runningAdler))
        }
        if sent - checkedAt >= 65_536 {
            checkedAt = sent
            return Frame(type: AirshipMessageType.check, payload: try cursor(sent, runningAdler))
        }
        let end = min(size, sent + 1024)
        let chunk = Array(data[sent..<end])
        runningAdler = Self.adler(chunk, seed: runningAdler)
        sent = end
        return Frame(type: AirshipMessageType.data, payload: chunk)
    }

    /// A reply from the receiver: a cursor (2) or the drop (7). Anything else stops the transfer.
    mutating func receive(type: Int, payload: [UInt8]) throws {
        do {
            guard state != .initial, state != .delivered, state != .failed else {
                throw failure("a reply arrived outside the transfer")
            }
            responses += 1
            guard responses <= 64 else { throw failure("too many replies") }
            guard type == AirshipMessageType.cursor || type == AirshipMessageType.drop else {
                throw failure("the glasses stopped the transfer (reply \(type))")
            }
            let fields = try checkedFields(payload, type: type)
            if type == AirshipMessageType.drop {
                guard fields.bytes(1) == uuid else { throw failure("the drop names another file") }
                guard state == .awaitingDrop else { throw failure("the glasses refused or dropped the file") }
                state = .finishing
                return
            }
            guard fields.has(2) else { throw failure("a cursor without a checksum") }
            let offset = fields.varint(1), checksum = fields.varint(2)
            guard offset >= 0, offset <= Int64(size), checksum >= 0, checksum <= Int64(UInt32.max) else {
                throw failure("an invalid cursor")
            }
            // A cursor may rewind, never jump past what was sent; its checksum must match our bytes before it.
            guard (sent == 0 && state == .awaitingCursor) || offset <= Int64(sent) else {
                throw failure("a cursor beyond the bytes sent")
            }
            let prefix = Self.adler(data.prefix(Int(offset)))
            guard prefix == UInt32(checksum) else { throw failure("the partial-file checksum did not match") }
            if offset < Int64(sent) {
                rewinds += 1
                guard rewinds <= 8 else { throw failure("too many rewinds") }
            }
            sent = Int(offset)
            checkedAt = sent
            runningAdler = prefix
            state = .streaming
        } catch {
            state = .failed
            throw error
        }
    }

    /// REMOVED for an unfinished file (the sender's withdrawal; DROP is the receiver's). Nil when there is nothing
    /// to withdraw.
    mutating func cancel() -> Frame? {
        guard state != .initial, state != .delivered, !withdrawn else { return nil }
        withdrawn = true
        state = .failed
        return Frame(type: AirshipMessageType.removed, payload: Wire.fieldBytes(1, uuid))
    }

    /// The glasses also offer files of their own on channels they open. ReGlass takes none: answer a well-formed offer
    /// with DROP so their queue moves on, without keeping anything. Nil for anything else.
    static func declineOffer(type: Int, payload: [UInt8]) -> Frame? {
        guard type == AirshipMessageType.offer || type == AirshipMessageType.peerOfferAlternate,
              payload.count <= 512 else { return nil }
        var offset = 0
        var id: [UInt8]?
        do {
            while offset < payload.count {
                let tag = try Wire.decodeVarint(payload, offset)
                let field = tag.value >> 3, kind = tag.value & 7
                guard field > 0, field <= Int64(Int32.max) else { return nil }
                offset = tag.offset
                if field == 1, kind != 2 || id != nil { return nil }
                switch kind {
                case 0:
                    offset = try Wire.decodeVarint(payload, offset).offset
                case 1, 5:
                    let width = kind == 1 ? 8 : 4
                    guard payload.count - offset >= width else { return nil }
                    offset += width
                case 2:
                    let length = try Wire.decodeVarint(payload, offset)
                    guard length.value >= 0, length.value <= Int64(payload.count - length.offset) else { return nil }
                    let end = length.offset + Int(length.value)
                    if field == 1 {
                        guard length.value == 16 else { return nil }
                        id = Array(payload[length.offset..<end])
                    }
                    offset = end
                default:
                    return nil
                }
            }
        } catch {
            return nil
        }
        guard let id else { return nil }
        return Frame(type: AirshipMessageType.drop, payload: Wire.fieldBytes(1, id))
    }

    // MARK: Helpers

    private func cursor(_ offset: Int, _ checksum: UInt32) throws -> [UInt8] {
        (try Wire.fieldVarint(1, Int64(offset))) + (try Wire.fieldVarint(2, Int64(checksum)))
    }

    /// A cursor holds varints 1 and 2; a drop holds bytes 1. At most 256 bytes, each field once.
    private func checkedFields(_ bytes: [UInt8], type: Int) throws -> Wire.Fields {
        guard bytes.count <= 256 else { throw failure("an oversized reply") }
        var offset = 0
        var seen = Set<Int>()
        while offset < bytes.count {
            let tag = try Wire.decodeVarint(bytes, offset)
            let field = Int(tag.value >> 3), kind = tag.value & 7
            guard tag.value > 0, (1...2).contains(field), seen.insert(field).inserted else {
                throw failure("invalid reply fields")
            }
            guard type == AirshipMessageType.cursor ? kind == 0 : (field == 1 && kind == 2) else {
                throw failure("invalid reply wire type")
            }
            offset = tag.offset
            if kind == 0 {
                offset = try Wire.decodeVarint(bytes, offset).offset
            } else {
                let length = try Wire.decodeVarint(bytes, offset)
                guard length.value >= 0, length.value <= Int64(bytes.count - length.offset) else {
                    throw failure("a truncated reply")
                }
                offset = length.offset + Int(length.value)
            }
        }
        return try Wire.parse(bytes)
    }

    private func failure(_ what: String) -> WakeWordFault {
        .transfer("\(filename): \(what)")
    }

    /// Adler-32, continued from `seed`.
    static func adler<S: Sequence>(_ bytes: S, seed: UInt32 = 1) -> UInt32 where S.Element == UInt8 {
        var a = seed & 0xFFFF, b = seed >> 16
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }
}
