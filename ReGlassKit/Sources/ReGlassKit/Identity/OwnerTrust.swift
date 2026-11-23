import Foundation

/// The svc36 trust exchange the session runs on every connection: ReGlass proves it holds the owner key the glasses
/// know, and acknowledges the glasses' own credential.
///
/// ReGlass sends message 0x1000 on a fresh svc36 channel. Tags 1, 2 and 3 carry the SHA-256 of the 64-byte
/// public key, the raw `r‖s` signature over the binding digest and the provisioning capabilities. The glasses
/// answer on the mirrored channel with a status of 0x1000 for acceptance.
/// The glasses send their credential (message 0x1000 or 0x1001) on a channel they open. ReGlass acknowledges
/// receipt with a success status on the mirrored channel without verifying the credential's contents.
///
/// The wait is bounded at 5 s; on expiry the partial result is returned, not an error. Messages that belong to
/// neither direction are handed back to the multiplexer for whoever reads next.
func ownerTrustHook(_ key: OwnerKey) -> TrustHook {
    { mux, binding in
        let payload = try enableTrustPayload(key, digest: binding.primary())
        let ourChannel = await mux.openChannel(DataXService.identity)
        try await mux.send(ourChannel, payload, messageType: IdentityMessageType.enableTrust,
                           serviceId: DataXService.identity)
        let ourStatusChannel = DataXMultiplexer.mirror(ourChannel)

        let progress = Locked(TrustProgress())
        do {
            try await withTimeout(ownerTrustTimeout, "owner trust") {
                while !progress.current.complete {
                    let message = try await mux.receive()
                    let info = message.info
                    if info.flags.hasError && info.channelId == ourStatusChannel {
                        progress.withLock {
                            if info.errorId == IdentityStatus.success { $0.txOk = true } else { $0.refusal = info.errorId }
                        }
                    } else if info.channelId & DataXChannel.originatorBit != 0,
                              info.serviceId == DataXService.identity,
                              peerCredentialMessageTypes.contains(info.messageType) {
                        try await mux.sendStatus(DataXMultiplexer.mirror(info.channelId), IdentityStatus.success)
                        progress.withLock { $0.rxOk = true }
                    } else {
                        progress.withLock { $0.unrelated.append(message) }
                    }
                }
            }
        } catch ReGlassError.timedOut {
            // The partial result is the verdict: the caller decides what a missing direction means.
        } catch {
            await mux.pushback(progress.current.unrelated)
            throw error
        }
        let result = progress.current
        await mux.pushback(result.unrelated)
        kitLog("ownership", "trust: accepted=\(result.txOk) peerCredential=\(result.rxOk)"
                 + (result.refusal.map { String(format: " refused=0x%04x", $0) } ?? ""))
        return TrustResult(txOk: result.txOk, rxOk: result.rxOk, refusal: result.refusal)
    }
}

/// Body of the svc36 trust request (message 0x1000). The signature uses the 32-byte digest as given.
func enableTrustPayload(_ key: OwnerKey, digest: [UInt8]) throws -> [UInt8] {
    Wire.fieldBytes(1, key.publicKeyDigest)
        + Wire.fieldBytes(2, try key.trustSignature(over: digest))
        + (try Wire.fieldVarint(3, Int64(provisioningCapabilitiesEC)))
}

/// Time allowed for both sides to answer the trust exchange.
let ownerTrustTimeout: Duration = .seconds(5)

private struct TrustProgress {
    var txOk = false
    var rxOk = false
    var refusal: Int?
    var unrelated: [DataXMessage] = []
    var complete: Bool { txOk && rxOk }
}

/// The message types the glasses use to push their own trust credential.
let peerCredentialMessageTypes: Set<Int> = [IdentityMessageType.enableTrust, IdentityMessageType.enableTrustEC]

extension GlassesLinkSession {
    /// The glasses turned ReGlass's key down on the current attempt: they did not accept it, yet they are clearly
    /// answering (they pushed their own credential, or `canaryAnswered`: svc100 replied). If they accepted the key
    /// it is never a refusal, whatever else went missing. Before any trust exchange there is no verdict.
    nonisolated func keyRefused(canaryAnswered: Bool) -> Bool {
        guard let trust = trustResult, !trust.txOk else { return false }
        return trust.rxOk || canaryAnswered
    }
}
