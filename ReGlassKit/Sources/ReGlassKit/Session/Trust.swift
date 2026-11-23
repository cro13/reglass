import Foundation

/// Which direction of the svc36 trust exchange completed.
struct TrustResult: Sendable, Equatable {
    /// The glasses accepted our owner credential.
    let txOk: Bool
    /// The glasses sent a credential of their own, which we acknowledged.
    let rxOk: Bool
    /// The status the glasses answered our credential with, when it was not success. Nil when they said nothing.
    let refusal: Int?

    init(txOk: Bool, rxOk: Bool, refusal: Int? = nil) {
        self.txOk = txOk
        self.rxOk = rxOk
        self.refusal = refusal
    }

    /// Both directions completed.
    var complete: Bool { txOk && rxOk }
}

/// The svc36 exchange the session runs between the handshake and EndLinkSetup. The Identity layer supplies the
/// body (it holds the owner key); it signs `binding.primary()` and reports which directions completed. It must
/// bound its own wait and leave any unrelated messages on the multiplexer (via pushback).
typealias TrustHook = @Sendable (DataXMultiplexer, HandshakeBinding) async throws -> TrustResult

/// Runs for every message of one service before the message is published. May send replies on the multiplexer.
typealias ServiceHandler = @Sendable (DataXMessage, DataXMultiplexer) async throws -> Void
