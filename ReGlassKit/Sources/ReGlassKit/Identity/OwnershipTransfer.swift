import Foundation

/// Identity reply on svc36 (message 0x3001), with the certificate at tag 1 and serial number at tag 2.
struct DeviceIdentity: Sendable {
    let certificate: [UInt8]
    let serial: String

    static func decode(_ data: [UInt8]) throws -> DeviceIdentity {
        let fields = try Wire.parse(data)
        let identity = DeviceIdentity(certificate: fields.bytes(1),
                                      serial: String(decoding: fields.bytes(2), as: Unicode.ASCII.self))
        guard !identity.certificate.isEmpty,
              !identity.serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReGlassError.protocolFailure("the identity response has no certificate or serial")
        }
        return identity
    }
}

/// The steps of a transfer, for progress.
enum OwnershipStep: Sendable {
    case identity, skipChallenge, pairRequest, startChangeOwner, pair, finishChangeOwner
}

/// Transfers ownership over svc36 with receipts from Meta's pairing service.
///
/// ReGlass reads the glasses' identity (0x3000) and asks for a nonce (0x2000). It gives those to Meta for a
/// pending receipt, then sends it to the glasses (0x2002). The glasses sign it, Meta issues the final receipt,
/// and the glasses confirm receipt of it (0x2004 request, 0x2005 reply).
///
/// Every svc36 message goes on one channel this side opens; only its first message names the service. Each wait is
/// bounded (20 s). Unrelated traffic is handed back to the multiplexer; trust pushes from the glasses are
/// acknowledged without sending an owner credential.
struct OwnershipTransfer {
    let mux: DataXMultiplexer
    let backend: PairingBackend
    let appPublicKey: [UInt8]
    let timeout: Duration

    /// Runs the conversation and returns the final receipt. `onIdentity` runs as soon as the glasses say who they
    /// are. `beforeOwnershipChange` runs just before sending the pending receipt (message 0x2002). Either callback
    /// can stop the exchange before the pending receipt is sent.
    func run(onStep: @escaping @Sendable (OwnershipStep) -> Void,
             onIdentity: @escaping @Sendable (DeviceIdentity) throws -> Void,
             beforeOwnershipChange: @escaping @Sendable () throws -> Void) async throws -> OwnershipReceipt {
        precondition(appPublicKey.count == 64, "the owner public key is 64 raw bytes")
        let channel = Svc36Channel(mux: mux, id: await mux.openChannel(DataXService.identity), timeout: timeout)
        do {
            let final = try await converse(channel, onStep: onStep, onIdentity: onIdentity,
                                           beforeOwnershipChange: beforeOwnershipChange)
            await mux.pushback(channel.takeUnrelated())
            return final
        } catch {
            await mux.pushback(channel.takeUnrelated())
            throw error
        }
    }

    private func converse(_ channel: Svc36Channel, onStep: @escaping @Sendable (OwnershipStep) -> Void,
                          onIdentity: @escaping @Sendable (DeviceIdentity) throws -> Void,
                          beforeOwnershipChange: @escaping @Sendable () throws -> Void) async throws -> OwnershipReceipt {
        onStep(.identity)
        try await channel.send(IdentityMessageType.identityRequest)
        let identity = try DeviceIdentity.decode(try await channel.receive(IdentityMessageType.identityResponse))
        try Task.checkCancellation()
        try onIdentity(identity)
        try Task.checkCancellation()

        onStep(.skipChallenge)
        try await channel.send(IdentityMessageType.skipChallenge)
        let ack = try await channel.receive(IdentityMessageType.skipChallengeAck)
        guard let nonce = try? Wire.parse(ack).bytes(1), !nonce.isEmpty else {
            throw ReGlassError.protocolFailure("SKIP_CHALLENGE_ACK has no device nonce")
        }

        onStep(.pairRequest)
        let backend = backend
        let appPublicKey = appPublicKey
        let pending = try await withTimeout(timeout, "Meta pair_request") {
            try await backend.pairRequest(certificate: identity.certificate, serial: identity.serial,
                                          deviceNonce: nonce, appPublicKey: appPublicKey)
        }
        guard pending.isWellFormed else { throw ReGlassError.protocolFailure("Meta's pending receipt is malformed") }

        try Task.checkCancellation()
        try beforeOwnershipChange()
        onStep(.startChangeOwner)
        try await channel.send(IdentityMessageType.startChangeOwnerRequest, pending.encoded())
        let devicePending = try OwnershipReceipt.decode(
            try await channel.receive(IdentityMessageType.startChangeOwnerResponse))
        guard devicePending.isWellFormed else {
            throw ReGlassError.protocolFailure("the glasses' pending receipt is malformed")
        }

        onStep(.pair)
        let final = try await withTimeout(timeout, "Meta pair") {
            try await backend.pair(devicePendingReceipt: devicePending)
        }
        guard final.isWellFormed else { throw ReGlassError.protocolFailure("Meta's final receipt is malformed") }
        guard final.field("serial") == identity.serial else {
            throw ReGlassError.protocolFailure("the final receipt names other glasses")
        }
        guard let userID = final.field("user_id"), !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReGlassError.protocolFailure("the final receipt has no user id")
        }

        onStep(.finishChangeOwner)
        try await channel.send(IdentityMessageType.finishChangeOwnerRequest, final.encoded())
        _ = try await channel.receive(IdentityMessageType.finishChangeOwnerResponse)
        try Task.checkCancellation()
        return final
    }
}

/// Reads the glasses' identity with svc36 message 0x3000. Used to recognise saved glasses whose Bluetooth ID changed.
func readDeviceIdentity(_ mux: DataXMultiplexer, timeout: Duration = .seconds(5)) async throws -> DeviceIdentity {
    let channel = Svc36Channel(mux: mux, id: await mux.openChannel(DataXService.identity), timeout: timeout)
    do {
        try await channel.send(IdentityMessageType.identityRequest)
        let identity = try DeviceIdentity.decode(try await channel.receive(IdentityMessageType.identityResponse))
        await mux.pushback(channel.takeUnrelated())
        return identity
    } catch {
        await mux.pushback(channel.takeUnrelated())
        throw error
    }
}

/// One svc36 channel this side opened, and the reading rules for its answers.
private final class Svc36Channel: @unchecked Sendable {
    let mux: DataXMultiplexer
    let id: Int
    let timeout: Duration
    // State behind `Locked`: whether the first message (which names the service) went out, peer channels known
    // to carry svc36, and messages that belong to someone else.
    private struct State {
        var sentFirst = false
        var peerIdentityChannels: Set<Int> = []
        var unrelated: [DataXMessage] = []
    }
    private let state = Locked(State())

    init(mux: DataXMultiplexer, id: Int, timeout: Duration) {
        self.mux = mux
        self.id = id
        self.timeout = timeout
    }

    func takeUnrelated() -> [DataXMessage] {
        state.withLock { state in
            defer { state.unrelated = [] }
            return state.unrelated
        }
    }

    func send(_ messageType: Int, _ payload: [UInt8] = []) async throws {
        try Task.checkCancellation()
        let first = state.withLock { state -> Bool in
            defer { state.sentFirst = true }
            return !state.sentFirst
        }
        try await mux.send(id, payload, messageType: messageType, serviceId: first ? DataXService.identity : nil)
    }

    /// The payload of the next `messageType` on this channel's mirror. Success statuses are skipped; any other
    /// status ends the wait (0x1042 means another Meta account owns the glasses).
    func receive(_ messageType: Int) async throws -> [UInt8] {
        let mirror = DataXMultiplexer.mirror(id)
        return try await withTimeout(timeout, String(format: "svc36 type 0x%04x", messageType)) { [self] in
            while true {
                try Task.checkCancellation()
                let message = try await mux.receive()
                let info = message.info
                let peerOpened = info.channelId & DataXChannel.originatorBit != 0
                if peerOpened, info.serviceId != 0 {
                    state.withLock {
                        if info.serviceId == DataXService.identity { $0.peerIdentityChannels.insert(info.channelId) }
                        else { $0.peerIdentityChannels.remove(info.channelId) }
                    }
                }
                if info.channelId == mirror, info.serviceId == 0 || info.serviceId == DataXService.identity {
                    if info.flags.hasError {
                        if info.errorId == IdentityStatus.success { continue }
                        if info.errorId == IdentityStatus.invalidUserId { throw ReGlassError.wrongOwnerAccount }
                        kitLog("ownership", String(format: "glasses answered 0x%04x while waiting for 0x%04x",
                                                     info.errorId, messageType))
                        throw ReGlassError.protocolFailure(String(format: "the glasses answered status 0x%04x", info.errorId))
                    }
                    if info.messageType == messageType { return message.payload }
                }
                let knownIdentityChannel = state.withLock { $0.peerIdentityChannels.contains(info.channelId) }
                if peerOpened,
                   info.serviceId == DataXService.identity || (info.serviceId == 0 && knownIdentityChannel),
                   !info.flags.hasError, peerCredentialMessageTypes.contains(info.messageType) {
                    try await mux.sendStatus(DataXMultiplexer.mirror(info.channelId), IdentityStatus.success)
                } else {
                    state.withLock { $0.unrelated.append(message) }
                }
            }
        }
    }
}
