import CommonCrypto
import CryptoKit
import Foundation

/// AirShield cipher failures: a MAC that did not verify, bad padding, or a failed AES call.
enum CryptoError: Error, Equatable {
    case authenticationFailed
    case invalidPadding
    case ciphertextNotAligned
    case frameTooShort
    case aesFailed(Int32)
    case badSecretSize(Int)
    case badIvSize(Int)
    case unsupportedParameters(Int)
}

/// Which way round the 32-bit sequence number goes into the MAC counter.
enum SeqEndian { case little, big }

/// AirShield per-frame cipher primitives: AES-256-CBC plus truncated HMAC-SHA256, encrypt-then-MAC.
enum AirShieldCipher {
    /// Truncated HMAC-SHA256 tag length.
    static let tagSize = 8
    /// AES / CBC block size.
    static let block = 16
    /// Modified PKCS#7: the pad byte is `padLen + 0xC0`.
    static let padOffset = 0xC0
    /// The NoQuirks 4-byte little-endian word ahead of the seq in the 8-byte MAC counter.
    static let counterPrefix: Int32 = 0x0000_0202

    /// QCS7 (QuirksMode) also signs the quirks byte in the counter's high byte (0x01000202).
    static func counterPrefix(forQuirks quirks: Int) -> Int32 {
        counterPrefix | ((Int32(truncatingIfNeeded: quirks) & 0xFF) &<< 24)
    }

    /// Modified PKCS#7. An aligned input gets a whole block, so there is always a pad.
    static func pad(_ data: [UInt8]) -> [UInt8] {
        let padLen = block - (data.count % block)   // 1...16
        let marker = UInt8(truncatingIfNeeded: (padLen + padOffset) & 0xFF)
        return data + [UInt8](repeating: marker, count: padLen)
    }

    static func unpad(_ data: [UInt8]) throws -> [UInt8] {
        guard !data.isEmpty, data.count % block == 0 else { throw CryptoError.ciphertextNotAligned }
        let last = Int(data[data.count - 1])
        let padLen = (last + 0x40) & 0xFF   // inverse of +0xC0
        guard (1...block).contains(padLen), padLen <= data.count else { throw CryptoError.invalidPadding }
        for i in (data.count - padLen)..<data.count where Int(data[i]) != last {
            throw CryptoError.invalidPadding
        }
        return Array(data[0..<(data.count - padLen)])
    }

    /// "AES/CBC/NoPadding": CommonCrypto with no options; a 32-byte key is AES-256.
    static func aesCbc(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
            key, key.count, iv, data, data.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { throw CryptoError.aesFailed(status) }
        return Array(out[0..<moved])
    }

    static func seqBytes(_ seq: Int32, _ endian: SeqEndian) -> [UInt8] {
        let bits = UInt32(bitPattern: seq)
        let little: [UInt8] = [
            UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24),
        ]
        return endian == .little ? little : little.reversed()
    }
}

/// Stateful per-direction crypto: `seal` for tx, `unseal` for rx on AirShield DATA frame bodies. Not thread
/// safe on its own; the secure channel serialises all access (tx on one path, rx on the reader).
final class FrameCrypto {
    private let seqEndian: SeqEndian
    private let chainIv: Bool
    private let counterPrefix: Int32
    private let aesKey: [UInt8]
    private let hmacKey: [UInt8]
    private var txIv: [UInt8]
    private var rxIv: [UInt8]
    // 32-bit counters that wrap.
    private var txSeq: Int32
    private var rxSeq: Int32

    init(
        _ keys: SessionKeys, seqEndian: SeqEndian = .little, chainIv: Bool = true,
        counterPrefix: Int32 = AirShieldCipher.counterPrefix, initTxSeq: Int32 = 0, initRxSeq: Int32 = 0
    ) throws {
        guard keys.aesKey.count == 32, keys.hmacKey.count == 32, keys.iv.count == AirShieldCipher.block else {
            throw CryptoError.badIvSize(keys.iv.count)
        }
        self.seqEndian = seqEndian
        self.chainIv = chainIv
        self.counterPrefix = counterPrefix
        txSeq = initTxSeq
        rxSeq = initRxSeq
        aesKey = keys.aesKey
        hmacKey = keys.hmacKey
        txIv = keys.iv
        rxIv = keys.iv
    }

    private func mac(seq: Int32, blockCount: Int, ciphertext: [UInt8]) -> [UInt8] {
        // 8-byte counter: the prefix as LE u32, then the seq, then the block count and the ciphertext.
        let ctr8 = AirShieldCipher.seqBytes(counterPrefix, .little) + AirShieldCipher.seqBytes(seq, seqEndian)
        let input = ctr8 + [UInt8(truncatingIfNeeded: blockCount)] + ciphertext
        let hmac = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: hmacKey))
        return Array(Array(hmac).prefix(AirShieldCipher.tagSize))
    }

    func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ciphertext = try AirShieldCipher.aesCbc(key: aesKey, iv: txIv, data: AirShieldCipher.pad(plaintext), encrypt: true)
        let blockCount = (ciphertext.count / AirShieldCipher.block) - 1
        guard (0...0xFF).contains(blockCount) else { throw CryptoError.frameTooShort }
        let tag = mac(seq: txSeq, blockCount: blockCount, ciphertext: ciphertext)
        let frame = tag + [UInt8(truncatingIfNeeded: blockCount)] + ciphertext
        if chainIv { txIv = Array(ciphertext[(ciphertext.count - AirShieldCipher.block)...]) }
        txSeq &+= 1
        return frame
    }

    /// Verify and decrypt one DATA frame body. With `verifyUnpad` false the DataX layer trims by header length
    /// instead, because the plaintext may be block-aligned with no pad byte.
    func unseal(_ frame: [UInt8], verifyUnpad: Bool = true) throws -> [UInt8] {
        guard frame.count >= AirShieldCipher.tagSize + 1 + AirShieldCipher.block else {
            throw CryptoError.frameTooShort
        }
        let tag = Array(frame[0..<AirShieldCipher.tagSize])
        let blockCount = Int(frame[AirShieldCipher.tagSize])
        let ciphertext = Array(frame[(AirShieldCipher.tagSize + 1)...])
        guard ciphertext.count == (blockCount + 1) * AirShieldCipher.block else {
            throw CryptoError.authenticationFailed
        }
        guard constantTimeEquals(tag, mac(seq: rxSeq, blockCount: blockCount, ciphertext: ciphertext)) else {
            throw CryptoError.authenticationFailed
        }
        var plaintext = try AirShieldCipher.aesCbc(key: aesKey, iv: rxIv, data: ciphertext, encrypt: false)
        if verifyUnpad { plaintext = try AirShieldCipher.unpad(plaintext) }
        if chainIv { rxIv = Array(ciphertext[(ciphertext.count - AirShieldCipher.block)...]) }
        rxSeq &+= 1
        return plaintext
    }
}
