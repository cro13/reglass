import Foundation

/// Makes ReGlass the owner of one pair of glasses, or reconnects to glasses it already owns, and verifies the result.
///
/// Order of operations (do not reorder):
/// 1. The owner key is sealed on disk before any token exchange or Bluetooth work. An existing key is always
///    reused; a second key is never generated.
/// 2. A pending record is saved before the ownership-changing messages.
/// 3. Glasses are marked verified only after a trusted reconnect: owner trust in both directions, READY, the
///    svc100 serial matching, and a measured battery reading. A failed verification leaves the stored state as it
///    was, except a refusal by the glasses, which is recorded.
///
/// `transfer` is the only path that talks to Meta or changes ownership; `reconnect` never does.
public final class GlassesOwnership: Sendable {
    private let glasses: UUID
    private let account: MetaAccount
    private let keeper = ConnectionKeeper()
    private let attempted = Locked(false)

    public init(glasses: UUID, account: MetaAccount) {
        self.glasses = glasses
        self.account = account
    }

    /// True once the pending receipt was sent (svc36 message 0x2002). Ownership may move even if the transfer fails.
    public var ownerChangeAttempted: Bool { attempted.current }

    // MARK: Transfer

    /// Makes ReGlass the owner (the Meta sign-in must be done). Reuses a saved key, never generates a second one.
    public func transfer(progress: @escaping @Sendable (SetupStage) -> Void) async throws -> GlassesSetupResult {
        do {
            guard let credentials = MetaClientCredentials.current else { throw ReGlassError.missingClientCredentials }
            let (key, reused) = try IdentityStore.ownerKeyCreatingIfNeeded()
            kitLog("ownership", reused ? "transfer: reusing the saved owner key" : "transfer: new owner key sealed")
            try Task.checkCancellation()

            progress(.account)
            let account = account
            let token = try await withTimeout(Self.stepTimeout, "Meta sign-in") { try await account.pairingToken() }
            guard !token.value.isEmpty, ["ar", "fb"].contains(token.universe) else { throw ReGlassError.signInRequired }
            let backend = PairingBackend(userToken: token.value, universe: token.universe, appToken: credentials.hardware)
            try Task.checkCancellation()

            progress(.connect)
            keeper.hold(glasses)
            defer { keeper.release() }
            let identity = try await changeOwner(key: key, backend: backend, progress: progress)

            let previous = try IdentityStore.record(serial: identity.serial)
            let record = IdentityRecord(glassesID: glasses, serial: identity.serial, state: .unverified,
                                        createdAt: previous?.createdAt ?? Date())
            try IdentityStore.save(record)
            kitLog("ownership", "ownership transferred; verifying with a trusted reconnect")
            try Task.checkCancellation()
            return try await verify(record, key: key, progress: progress)
        } catch {
            let mapped = ReGlassError.from(error)
            kitLog("ownership", "transfer stopped: \(mapped)" + (ownerChangeAttempted ? " (after the ownership step)" : ""))
            throw mapped
        }
    }

    /// One encrypted link, the svc36 conversation, then the link closes. Returns the identity the glasses reported.
    private func changeOwner(key: OwnerKey, backend: PairingBackend,
                             progress: @escaping @Sendable (SetupStage) -> Void) async throws -> DeviceIdentity {
        let glasses = glasses
        let attempted = attempted
        let reported = Locked<DeviceIdentity?>(nil)
        try await withOpenLink(to: glasses) { mux in
            let transfer = OwnershipTransfer(mux: mux, backend: backend, appPublicKey: key.publicKey64,
                                             timeout: Self.stepTimeout)
            _ = try await transfer.run(onStep: { step in
                switch step {
                case .identity: progress(.connect)
                case .startChangeOwner:
                    attempted.withLock { $0 = true }
                    progress(.ownership)
                default: progress(.ownership)
                }
                kitLog("ownership", "step: \(step)")
            }, onIdentity: { identity in
                reported.withLock { $0 = identity }
                // Same glasses, already verified: keep that record. If this transfer stops before the ownership
                // step nothing changed on the glasses, and the live connection must still find them verified.
                if let existing = try IdentityStore.record(serial: identity.serial),
                   existing.state == .verified, existing.glassesID == glasses {
                    kitLog("ownership", "verified record kept while the same key is registered again")
                    return
                }
                try IdentityStore.save(IdentityRecord(glassesID: glasses, serial: identity.serial, state: .pending,
                                                      createdAt: Date()))
                kitLog("ownership", "pending record saved before the ownership change")
            }, beforeOwnershipChange: {
                // From here ownership may move: a record kept verified above becomes pending until verified again.
                guard let serial = reported.current?.serial else {
                    throw ReGlassError.protocolFailure("no identity before the ownership change")
                }
                try IdentityStore.setState(.pending, serial: serial)
            })
        }
        guard let identity = reported.current else { throw ReGlassError.protocolFailure("no identity was reported") }
        return identity
    }

    // MARK: Reconnect

    /// Reconnects with ReGlass's saved key and verifies it. No Meta sign-in, no Meta requests, no ownership change.
    public func reconnect(progress: @escaping @Sendable (SetupStage) -> Void) async throws -> GlassesSetupResult {
        do {
            guard let key = try IdentityStore.ownerKey() else { throw ReGlassError.noSavedIdentity }
            let records = try IdentityStore.records()
            guard !records.isEmpty else { throw ReGlassError.noSavedIdentity }
            kitLog("ownership", "reconnect with the saved key; no sign-in, no ownership change")

            progress(.connect)
            keeper.hold(glasses)
            defer { keeper.release() }
            let record: IdentityRecord
            let byID = records.filter { $0.glassesID == glasses }
            if byID.count == 1 {
                record = byID[0]
            } else {
                // iOS can hand the same glasses a new Bluetooth id: recognise them by serial (read-only query).
                kitLog("ownership", "no saved record for this Bluetooth id; reading the serial")
                let serial = try await readSerial()
                let bySerial = records.filter { $0.serial == serial }
                guard bySerial.count == 1 else { throw ReGlassError.noSavedIdentity }
                record = bySerial[0]
            }
            return try await verify(record, key: key, progress: progress)
        } catch {
            let mapped = ReGlassError.from(error)
            kitLog("ownership", "reconnect stopped: \(mapped)")
            throw mapped
        }
    }

    private func readSerial() async throws -> String {
        let reported = Locked<String?>(nil)
        try await withOpenLink(to: glasses) { mux in
            let identity = try await readDeviceIdentity(mux)
            reported.withLock { $0 = identity.serial }
        }
        guard let serial = reported.current else { throw ReGlassError.noSavedIdentity }
        return serial
    }

    // MARK: Verification

    private struct Verified: Sendable {
        let battery: Int
        let info: PeerDeviceInfo?
    }

    /// The trusted reconnect: a full session with the owner trust exchange, within 60 s.
    private func verify(_ record: IdentityRecord, key: OwnerKey,
                        progress: @escaping @Sendable (SetupStage) -> Void) async throws -> GlassesSetupResult {
        progress(.secure)
        let id = glasses
        let session = GlassesLinkSession(transport: { L2CAPTransport(glasses: id) }, trust: ownerTrustHook(key))
        await session.start()
        let verified: Verified
        do {
            verified = try await withTaskCancellationHandler {
                try await withTimeout(Self.verificationTimeout, "verification") {
                    try await Self.awaitVerification(session, expectedSerial: record.serial, progress: progress)
                }
            } onCancel: {
                Task { await session.stop() }
            }
        } catch {
            await session.stop()
            switch error as? ReGlassError {
            case .keyRefused?:
                // A true refusal is the one outcome a failed verification records.
                try? IdentityStore.setState(.refused, serial: record.serial)
                throw ReGlassError.keyRefused
            case .timedOut?:
                throw ReGlassError.verificationIncomplete
            default:
                throw error
            }
        }
        await session.stop()   // let go of the glasses before the record changes

        let confirmed = IdentityRecord(glassesID: glasses, serial: record.serial, state: .verified,
                                       createdAt: record.createdAt)
        try IdentityStore.save(confirmed)
        kitLog("ownership", record.glassesID == glasses ? "verified; owner key unchanged"
                 : "verified and moved to the current Bluetooth id; owner key unchanged")
        return GlassesSetupResult(serial: record.serial, batteryPercent: verified.battery,
                                  firmware: verified.info?.firmware.nilIfEmpty, model: verified.info?.model.nilIfEmpty)
    }

    /// Reads the session until it passes, or throws `.keyRefused` / `.serialMismatch` / `.linkLost`.
    private static func awaitVerification(_ session: GlassesLinkSession, expectedSerial: String,
                                          progress: @escaping @Sendable (SetupStage) -> Void) async throws -> Verified {
        var ready = false
        var info: PeerDeviceInfo?
        var battery: Int?
        for await event in session.events {
            switch event {
            case .state(.connecting, _):
                ready = false
                info = nil
                battery = nil
            case .state(.ready, _):
                if session.keyRefused(canaryAnswered: false) { throw ReGlassError.keyRefused }
                ready = true
                progress(.finish)
                session.submit { mux in _ = try await DeviceRequests.onReady(mux) }
            case .state(.lost, _), .state(.disconnected, _):
                ready = false
                if session.keyRefused(canaryAnswered: false) { throw ReGlassError.keyRefused }
            case .serviceMessage(let service, let type, let payload):
                if service == DataXService.peerBuildInfo, type == PeerBuildInfoMessageType.peerDeviceInfo,
                   let decoded = try? PeerDeviceInfo.decode(payload) {
                    if !decoded.serial.isEmpty, decoded.serial != expectedSerial { throw ReGlassError.serialMismatch }
                    if session.keyRefused(canaryAnswered: true) { throw ReGlassError.keyRefused }
                    info = decoded
                } else if service == DataXService.status, DeviceStateReading.isDeviceState(type),
                          let percent = (try? DeviceStateReading.decode(payload))?.batteryPercent {
                    battery = percent
                }
            default:
                break
            }
            if ready, session.trustComplete, info?.serial == expectedSerial, let battery {
                kitLog("ownership", "trust complete both ways; serial matches; battery \(battery)%")
                return Verified(battery: battery, info: info)
            }
        }
        throw ReGlassError.linkLost
    }

    // MARK: Links without a session (transfer, serial query)

    /// Connects, opens the encrypted link and a multiplexer, runs `body`, and always closes the link.
    private func withOpenLink(to glasses: UUID,
                              _ body: @escaping @Sendable (DataXMultiplexer) async throws -> Void) async throws {
        let transport = L2CAPTransport(glasses: glasses)
        var reader: Task<Void, Never>?
        do {
            try await withTaskCancellationHandler {
                try await Self.withDeadline(Self.stepTimeout, "connecting to the glasses", transport) {
                    try await transport.connect()
                }
                let channel = SecureChannel(transport)
                try await Self.withDeadline(Self.linkSetupTimeout, "link setup", transport) { try await channel.open() }
                let mux = DataXMultiplexer(channel, ChannelRegistry())
                reader = try await mux.startReader()
                try await body(mux)
            } onCancel: {
                transport.close()
            }
        } catch {
            transport.close()
            if let reader { reader.cancel(); await reader.value }
            throw error
        }
        // Close before joining the reader: cancelling alone may not wake a read blocked on the socket.
        transport.close()
        if let reader { reader.cancel(); await reader.value }
    }

    /// Bounds a link step: when `timeout` passes, the transport is closed, which ends
    /// any wait on it, a write the glasses never take included (cancelling can't reach one). A step that finished
    /// first keeps its link.
    private static func withDeadline<T>(_ timeout: Duration, _ what: String, _ transport: FrameTransport,
                                        _ body: () async throws -> T) async throws -> T {
        let settled = Locked(false)
        let claim = { settled.withLock { already -> Bool in defer { already = true }; return !already } }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled, claim() { transport.close() }
        }
        defer { watchdog.cancel() }
        do {
            let result = try await body()
            guard claim() else { throw ReGlassError.timedOut(what) }
            return result
        } catch {
            if error is CancellationError { throw error }
            // The watchdog got there first: this failure is the deadline.
            if !claim() { throw ReGlassError.timedOut(what) }
            throw error
        }
    }

    /// The provisioning wait per step and for the serial query (20 s, as measured with these glasses).
    private static let stepTimeout: Duration = .seconds(20)
    /// Link setup is bounded at 10 s, as in the session.
    private static let linkSetupTimeout: Duration = .seconds(10)
    /// Trust, READY, serial and battery must all be confirmed within 60 s.
    private static let verificationTimeout: Duration = .seconds(60)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
