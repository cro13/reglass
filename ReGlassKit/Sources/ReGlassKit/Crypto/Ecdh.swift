import CryptoKit
import Foundation

/// An ephemeral P-256 key pair with its public half already in wire form (64 raw bytes, `x ‖ y`).
struct EphemeralKeyPair {
    let privateKey: P256.KeyAgreement.PrivateKey
    let publicKey64: [UInt8]
}

/// ECDH on secp256r1 (NIST P-256). Public keys travel as 64 raw bytes, `x ‖ y`, no `0x04` prefix.
enum Ecdh {

    /// A fresh ephemeral key pair for one handshake.
    static func generateEphemeral() -> EphemeralKeyPair {
        let key = P256.KeyAgreement.PrivateKey()
        return EphemeralKeyPair(privateKey: key, publicKey64: Array(key.publicKey.rawRepresentation))
    }

    /// ECDH agreement to the 32-byte shared secret (the raw X coordinate of the shared point).
    static func sharedSecret(_ privateKey: P256.KeyAgreement.PrivateKey, peerPublic64: [UInt8]) throws -> [UInt8] {
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublic64)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
    }
}
