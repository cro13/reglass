import CryptoKit
import Foundation

/// One direction's AirShield key set: AES-256, HMAC-SHA256, and the initial CBC IV.
struct SessionKeys: Equatable {
    /// 32 bytes.
    let aesKey: [UInt8]
    /// 32 bytes.
    let hmacKey: [UInt8]
    /// 16 bytes, the preamble nonce, which is this direction's initial CBC IV.
    let iv: [UInt8]
}

/// Derives AirShield session keys for each direction of the link.
enum Kdf {

    static let airShieldInfo: [UInt8] = Array("AirShield".utf8)
    private static let hmacDeriveLabel: [UInt8] = Array("hmac_derive".utf8)

    /// The QCS7 HKDF context contains the label in a zero-filled 128-byte buffer followed by the little-endian
    /// UInt32 values 32 and 256.
    static let qcs7Info: [UInt8] = airShieldInfo +
        [UInt8](repeating: 0, count: 128 - airShieldInfo.count) + [0x20, 0, 0, 0, 0, 0x01, 0, 0]

    /// Selects the HKDF info from the peer's quirks value. The value 1 selects the QCS7 context.
    static func info(forQuirks quirks: Int) -> [UInt8] { quirks == 1 ? qcs7Info : airShieldInfo }

    /// Derive one direction's key set. Only the two measured parameter sets (27, 31) are supported; other
    /// modes must not be silently keyed as 31.
    static func deriveDirectionKeys(
        ecdhSecret: [UInt8], nonce: [UInt8], seed: [UInt8], preambleIv: [UInt8],
        info: [UInt8], parameters: Int
    ) throws -> SessionKeys {
        guard ecdhSecret.count == 32 else { throw CryptoError.badSecretSize(ecdhSecret.count) }
        guard preambleIv.count == 16 else { throw CryptoError.badIvSize(preambleIv.count) }
        guard parameters == 27 || parameters == 31 else { throw CryptoError.unsupportedParameters(parameters) }

        let aesSalt = sha256(nonce, seed)
        let aesKey = hkdfExpand(hkdfExtract(salt: aesSalt, ikm: ecdhSecret), info: info, length: 32)
        // Bit 2 is Multikey. Mode 27 reuses the AES-derived key for HMAC; mode 31 derives it separately.
        // Independent of the QCS7 HKDF-info quirk.
        let hmacKey: [UInt8]
        if parameters & 0x04 != 0 {
            let hmacSalt = sha256(seed, nonce, hmacDeriveLabel)
            hmacKey = hkdfExpand(hkdfExtract(salt: hmacSalt, ikm: ecdhSecret), info: info, length: 32)
        } else {
            hmacKey = aesKey
        }
        return SessionKeys(aesKey: aesKey, hmacKey: hmacKey, iv: preambleIv)
    }

    private static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var digest = SHA256()
        for part in parts { digest.update(data: part) }
        return Array(digest.finalize())
    }

    private static func hmacSha256(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hkdfExtract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] { hmacSha256(salt, ikm) }

    private static func hkdfExpand(_ prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length + 32)
        var t = [UInt8]()
        var counter = 1
        while out.count < length {
            t = hmacSha256(prk, t + info + [UInt8(truncatingIfNeeded: counter)])
            out += t
            counter += 1
        }
        return Array(out.prefix(length))
    }
}
