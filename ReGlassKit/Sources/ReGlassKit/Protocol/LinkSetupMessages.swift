import Foundation

// AirShield link-setup messages. Keep field numbers and omission rules compatible with the glasses.

/// First handshake message: the initiator proposes ECDH parameters.
struct RequestEncryption: Equatable {
    var publicKey: [UInt8]
    var challenge: [UInt8]
    var ellipticCurve = 0
    var supportedParameters = 31
    var keyHint: [[UInt8]] = []
    var quirks = 0
    var airshieldVersion = 16

    func encode() throws -> [UInt8] {
        var parts = Wire.fieldBytes(1, publicKey)
        parts += Wire.fieldBytes(2, challenge)
        parts += try Wire.fieldVarint(3, Int64(ellipticCurve))
        parts += try Wire.fieldVarint(4, Int64(supportedParameters))
        for hint in keyHint { parts += Wire.fieldBytes(5, hint) }
        // Omit field 6 when quirks is zero.
        if quirks != 0 { parts += try Wire.fieldVarint(6, Int64(quirks)) }
        parts += try Wire.fieldVarint(7, Int64(airshieldVersion))
        return parts
    }

    static func decode(_ data: [UInt8]) throws -> RequestEncryption {
        let f = try Wire.parse(data)
        return RequestEncryption(
            publicKey: f.bytes(1),
            challenge: f.bytes(2),
            ellipticCurve: Int(Int32(truncatingIfNeeded: f.varint(3))),
            supportedParameters: Int(Int32(truncatingIfNeeded: f.varint(4))),
            keyHint: f.repeatedBytes(5),
            quirks: Int(Int32(truncatingIfNeeded: f.varint(6))),
            airshieldVersion: Int(Int32(truncatingIfNeeded: f.varint(7)))
        )
    }
}

/// Second handshake message: the responder accepts and provides the seed and IV.
struct EnableEncryption: Equatable {
    var publicKey: [UInt8]
    var seed: [UInt8]
    var iv: [UInt8]
    /// The sender's preamble sequence counter, an unsigned 32-bit value drawn from random bytes.
    var base: Int64 = 0
    var parameters = 31
    var quirks = 0
    var phasedLinkSetupSupported = 0
    var supportedLinkSetupServices: Int64 = 0
    var linkSwitchVersionSupported = 0

    /// Always sends fields 1–5 and omits any of fields 6–9 whose value is zero.
    func encode() throws -> [UInt8] {
        var parts = Wire.fieldBytes(1, publicKey)
        parts += Wire.fieldBytes(2, seed)
        parts += Wire.fieldBytes(3, iv)
        parts += try Wire.fieldVarint(4, base)
        parts += try Wire.fieldVarint(5, Int64(parameters))
        if quirks != 0 { parts += try Wire.fieldVarint(6, Int64(quirks)) }
        if phasedLinkSetupSupported != 0 { parts += try Wire.fieldVarint(7, Int64(phasedLinkSetupSupported)) }
        // Field 8 is a u64 bitmask: encode its bit pattern unsigned.
        if supportedLinkSetupServices != 0 { parts += Wire.fieldVarintUnsigned(8, supportedLinkSetupServices) }
        if linkSwitchVersionSupported != 0 { parts += try Wire.fieldVarint(9, Int64(linkSwitchVersionSupported)) }
        return parts
    }

    static func decode(_ data: [UInt8]) throws -> EnableEncryption {
        let f = try Wire.parse(data)
        return EnableEncryption(
            publicKey: f.bytes(1),
            seed: f.bytes(2),
            iv: f.bytes(3),
            base: f.varint(4),
            parameters: Int(Int32(truncatingIfNeeded: f.varint(5))),
            quirks: Int(Int32(truncatingIfNeeded: f.varint(6))),
            phasedLinkSetupSupported: Int(Int32(truncatingIfNeeded: f.varint(7))),
            supportedLinkSetupServices: f.varint(8),
            linkSwitchVersionSupported: Int(Int32(truncatingIfNeeded: f.varint(9)))
        )
    }
}

/// Final handshake message: the encrypted stream is ready. Field 4 (user data) is never sent by the phone.
struct EndLinkSetup {
    var asMain = 1
    /// 16 bytes, RFC 4122 v4.
    var scopeUuid: [UInt8]
    /// 16 bytes, RFC 4122 v4.
    var leaseUuid: [UInt8]

    func encode() throws -> [UInt8] {
        // The firmware checks (b[6] & 0xf0) == 0x40 and (b[8] & 0xc0) == 0x80 and tears the channel down
        // silently otherwise, so the UUIDs must be valid v4. LinkUUID.random() guarantees it.
        precondition(LinkUUID.isValid(scopeUuid) && LinkUUID.isValid(leaseUuid),
                     "EndLinkSetup UUIDs must be RFC 4122 v4")
        return try Wire.fieldVarint(1, Int64(asMain)) + Wire.fieldBytes(2, scopeUuid) + Wire.fieldBytes(3, leaseUuid)
    }
}

/// The 16-byte UUIDs EndLinkSetup carries, and the firmware check they must pass.
enum LinkUUID {
    /// 16 bytes from Foundation's `UUID()`, which is version 4 and variant 10xx by construction.
    static func random() -> [UInt8] {
        let u = UUID().uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        precondition(isValid(bytes), "UUID() produced a UUID the firmware would reject")
        return bytes
    }

    static func isValid(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && (bytes[6] & 0xF0) == 0x40 && (bytes[8] & 0xC0) == 0x80
    }
}
