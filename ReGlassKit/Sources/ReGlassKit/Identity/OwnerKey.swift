import CryptoKit
import Foundation
import Security

/// ReGlass's P-256 owner key: the private half ReGlass keeps, the raw public half the glasses recognise, and the
/// trust signature a reconnect signs. The private key never leaves this type; only its PKCS#8 PEM is stored
/// (sealed) and only the public half and signatures go on the wire.
struct OwnerKey: Sendable {
    /// PKCS#8 PEM, as `P256.Signing.PrivateKey.pemRepresentation` writes it. Stored sealed; never logged.
    let pem: [UInt8]
    /// The public half as 64 raw bytes, `x ‖ y`, no `0x04` prefix. The glasses key on `SHA256` of these bytes.
    let publicKey64: [UInt8]

    // x9.63 bytes feed SecKey, which signs an already-hashed digest (NONEwithECDSA); CryptoKit would hash again.
    private let x963: [UInt8]

    private init(key: P256.Signing.PrivateKey, pem: [UInt8]) {
        self.pem = pem
        publicKey64 = key.publicKey.rawRepresentation.byteArray
        x963 = key.x963Representation.byteArray
    }

    /// A fresh owner key. Only `transfer` creates one, and only when none is stored.
    static func generate() -> OwnerKey {
        let key = P256.Signing.PrivateKey()
        return OwnerKey(key: key, pem: Array(key.pemRepresentation.utf8))
    }

    /// Load the stored key. Throws when the PEM is not a usable P-256 private key.
    static func load(pem: [UInt8]) throws -> OwnerKey {
        let text = String(decoding: pem, as: UTF8.self)
        do {
            return OwnerKey(key: try P256.Signing.PrivateKey(pemRepresentation: text), pem: pem)
        } catch {
            throw ReGlassError.protocolFailure("the stored owner key is not a usable P-256 key")
        }
    }

    /// SHA-256 of the 64-byte raw public key, sent in tag 1 of the svc36 trust request (message 0x1000).
    var publicKeyDigest: [UInt8] { Array(SHA256.hash(data: publicKey64)) }

    /// Sign the 32-byte channel-binding digest for svc36 trust: ECDSA P-256 over the digest *as given* (never
    /// hashed again), returned raw as `r ‖ s` (64 bytes) with `s` folded into the low half of the group order.
    func trustSignature(over digest: [UInt8]) throws -> [UInt8] {
        guard digest.count == 32 else {
            throw ReGlassError.protocolFailure("the channel binding must be a 32-byte digest")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(Data(x963) as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            throw ReGlassError.protocolFailure("the owner key will not load for signing")
        }
        guard let der = SecKeyCreateSignature(secKey, .ecdsaSignatureDigestX962SHA256, Data(digest) as CFData, &error) else {
            error?.release()
            throw ReGlassError.protocolFailure("the owner key would not sign")
        }
        let (r, s) = try Self.decodeDerSignature((der as Data).byteArray)
        let folded = beGreater(s, Self.halfOrder) ? beSubtract(Self.order, s) : s
        return r + folded
    }

    // MARK: DER ECDSA signature

    /// Split an X9.62 DER signature into its two 32-byte big-endian coordinates.
    private static func decodeDerSignature(_ der: [UInt8]) throws -> (r: [UInt8], s: [UInt8]) {
        var at = 0
        func byte() throws -> Int {
            guard at < der.count else { throw ReGlassError.protocolFailure("the signature is truncated") }
            defer { at += 1 }
            return Int(der[at])
        }
        func length() throws -> Int {
            let first = try byte()
            // P-256 signatures only ever use the short form.
            guard first < 0x80 else { throw ReGlassError.protocolFailure("the signature is not in the expected format") }
            return first
        }
        func integer() throws -> [UInt8] {
            guard try byte() == 0x02 else { throw ReGlassError.protocolFailure("the signature is not in the expected format") }
            let len = try length()
            guard at + len <= der.count else { throw ReGlassError.protocolFailure("the signature is truncated") }
            let raw = Array(der[at..<(at + len)])
            at += len
            return try fixedWidth(raw)
        }
        guard try byte() == 0x30 else { throw ReGlassError.protocolFailure("the signature is not in the expected format") }
        _ = try length()
        return (try integer(), try integer())
    }

    /// A DER INTEGER as exactly 32 big-endian bytes (drop a sign byte, left-pad a short value).
    private static func fixedWidth(_ bytes: [UInt8]) throws -> [UInt8] {
        let stripped = Array(bytes.drop(while: { $0 == 0 }))
        guard stripped.count <= 32 else { throw ReGlassError.protocolFailure("the signature does not fit a P-256 coordinate") }
        return [UInt8](repeating: 0, count: 32 - stripped.count) + stripped
    }

    // MARK: Fixed-width P-256 order arithmetic (32-byte big-endian, no BigInteger needed)

    /// The secp256r1 group order n.
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]
    /// n >> 1: s above this is folded to n - s.
    private static let halfOrder: [UInt8] = shiftRight1(order)
}

/// a > b for equal-length big-endian magnitudes.
private func beGreater(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    for i in 0..<a.count where a[i] != b[i] { return a[i] > b[i] }
    return false
}

/// a - b for equal-length big-endian magnitudes, a >= b.
private func beSubtract(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: a.count)
    var borrow = 0
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        var v = Int(a[i]) - Int(b[i]) - borrow
        borrow = v < 0 ? 1 : 0
        if v < 0 { v += 256 }
        out[i] = UInt8(v)
    }
    return out
}

/// value >> 1 for a big-endian magnitude.
private func shiftRight1(_ value: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: value.count)
    var carry: UInt8 = 0
    for (i, b) in value.enumerated() {
        out[i] = b >> 1 | carry
        carry = b << 7
    }
    return out
}
