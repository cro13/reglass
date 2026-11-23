import CryptoKit
import Foundation

/// The reconnect channel binding, the "TX challenge". `primary()` is the 32-byte digest the svc36 trust
/// exchange signs; the glasses refuse (0x1043) a signature over anything else, so its inputs must not change.
struct HandshakeBinding: Equatable {
    /// 16 bytes, the glasses' RequestEncryption challenge.
    let glChallenge: [UInt8]
    /// 32 bytes, our EnableEncryption seed.
    let mySeed: [UInt8]
    /// 64 raw bytes, the glasses' RequestEncryption public key.
    let glReqPub: [UInt8]
    /// 64 raw bytes, our ephemeral public key.
    let myPub: [UInt8]

    /// `getTxChallenge`: the peer's challenge with the peer's RequestEncryption pubkey, crossed with our seed
    /// and our pubkey. `SHA256( SHA256(glChallenge ‖ glReqPub) ‖ SHA256(mySeed ‖ myPub) )`.
    func primary() -> [UInt8] {
        Self.sha(Self.sha(glChallenge, glReqPub), Self.sha(mySeed, myPub))
    }

    private static func sha(_ parts: [UInt8]...) -> [UInt8] {
        var digest = SHA256()
        for part in parts { digest.update(data: part) }
        return Array(digest.finalize())
    }
}
