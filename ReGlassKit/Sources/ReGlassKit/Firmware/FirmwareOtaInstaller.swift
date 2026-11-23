import Foundation

// The Firmware page asks the wearer to confirm before starting an update with `allowApply: true`.
// A debug rehearsal stages the full image and withdraws it before sending Airship COMPLETE (6).
//
// The installer starts OTA on svc28, requests installation on svc29, and sends the validated image over Airship.
// It sends COMPLETE only at the end of the image with `allowApply` set, then answers a matching-UUID DROP (7)
// with REMOVED (8). The glasses apply the image and reboot. ReGlass reconnects and verifies the running build
// on svc100 with bounded retries.
//
// The installer checks the glasses' reported battery against a 60% floor before transferring and before
// sending COMPLETE. The glasses also enforce their own power policy and cannot update while charging.

/// Why a firmware install stopped, in log-safe words.
public enum FirmwareInstallFault: Error, CustomStringConvertible, Equatable, Sendable {
    /// The image was staged with `allowApply` set to false. This is the expected outcome of a rehearsal.
    case applyGateClosed
    /// A firmware install is already running on this installer.
    case busy
    /// The server now offers a different version than the one selected on the Firmware page.
    case offerChanged(String)
    /// The offer asks for a factory wipe (`POWERWASH=1`) and `allowPowerwash` was not set.
    case powerwashNotAllowed
    /// The install plan failed validation (shape, offset, size, …).
    case planInvalid(String)
    /// The glasses have not reported their battery on this link, so the battery floor cannot be checked.
    case batteryUnknown
    /// The glasses' battery is below ReGlass's update floor (`FirmwareBatteryFloor`).
    case lowBattery(percent: Int, needed: Int)
    /// The device rejected the install or dropped a frame we did not expect.
    case deviceRefused(String)
    /// A mid-transfer link drop on a NON-resumable transfer: the attempt must restart from svc28 with a fresh key.
    case midTransferDrop
    /// The device reported apply/reboot progress while the apply gate was closed — it must never happen.
    case unexpectedApply
    /// Observation stopped (timeout, cancellation, …) after COMPLETE may have reached the device. The device decides
    /// the outcome on its own; do not retry — confirm the running build later.
    case applyOutcomeUnknown(String)
    /// The post-reboot svc100 build did not match the target.
    case confirmMismatch(got: String, want: String)
    /// A bounded wait ran out.
    case timedOut(String)

    public var description: String {
        switch self {
        case .applyGateClosed: return "the apply gate is closed (allowApply == false); COMPLETE was not sent"
        case .busy: return "a firmware install is already running"
        case .offerChanged(let version): return "the firmware offer changed to version \(version)"
        case .powerwashNotAllowed: return "the offer requests POWERWASH (factory wipe) and it was not allowed"
        case .planInvalid(let what): return "install plan invalid (\(what))"
        case .batteryUnknown: return "the glasses did not report their battery; not updating"
        case .lowBattery(let percent, let needed):
            return "the glasses' battery is \(percent) %, below the \(needed) % needed to update; charge them first"
        case .deviceRefused(let what): return "the device refused (\(what))"
        case .midTransferDrop: return "the link dropped mid-transfer (non-resumable); restart from svc28"
        case .unexpectedApply: return "the device entered apply/reboot while the apply gate was closed"
        case .applyOutcomeUnknown(let what):
            return "the apply was authorized but observation stopped (\(what)); confirm the build before retrying"
        case .confirmMismatch(let got, let want): return "post-reboot build \(got) does not match target \(want)"
        case .timedOut(let what): return "timed out waiting for \(what)"
        }
    }
}

/// The battery floor for a firmware update — ReGlass's own rule, NOT a
/// Meta constant: Meta's companion has no phone-side gate and leaves the decision to the glasses. Checked before the
/// ~20-minute transfer (so a doomed run never starts) and again right before COMPLETE (so the apply starts with
/// enough charge). The value is what the glasses report on their own (no extra request); charging is irrelevant.
enum FirmwareBatteryFloor {
    static let minimumPercent = 60

    static func check(_ percent: Int?) throws {
        guard let percent else { throw FirmwareInstallFault.batteryUnknown }
        guard percent >= minimumPercent else {
            throw FirmwareInstallFault.lowBattery(percent: percent, needed: minimumPercent)
        }
    }
}

/// A validated firmware install plan: the whole downloaded image (transferred verbatim), the offset/headers/KEK the
/// device reads to interpret it, a fresh transfer id, and the install key. Built once and checked before anything
/// goes to the glasses. It refuses a POWERWASH offer unless `allowPowerwash` is set.
struct FirmwareInstallPlan: Sendable {
    let offer: FirmwareOffer
    /// The whole image bytes, transferred verbatim (we never strip or seek the package ourselves).
    let image: [UInt8]
    let fileUuid: [UInt8]
    let key: ResourceOta.Key

    static func build(offer: FirmwareOffer, image: [UInt8], fileUuid: [UInt8], key: ResourceOta.Key,
                      allowPowerwash: Bool) throws -> FirmwareInstallPlan {
        guard image.count >= 2, image.count == offer.fileSize else {
            throw FirmwareInstallFault.planInvalid("image size \(image.count) != offer \(offer.fileSize)")
        }
        guard fileUuid.count == 16 else { throw FirmwareInstallFault.planInvalid("file id") }
        // The payload must be a real span inside the file we send whole: offset in [0, fileSize) and
        // offset + payloadSize <= fileSize. (`FirmwareOffer` already enforces this and the Orca container shape.)
        guard offer.payloadOffset >= 0, offer.payloadOffset < Int64(offer.fileSize), offer.payloadSize > 0,
              Int64(offer.payloadSize) <= Int64(offer.fileSize) - offer.payloadOffset else {
            throw FirmwareInstallFault.planInvalid("payload offset \(offer.payloadOffset)/size \(offer.payloadSize)")
        }
        if offer.powerwash {
            kitLog("firmware", "WARNING: offer requests POWERWASH (factory wipe)")
            guard allowPowerwash else { throw FirmwareInstallFault.powerwashNotAllowed }
        }
        return FirmwareInstallPlan(offer: offer, image: image, fileUuid: fileUuid, key: key)
    }
}

/// Sends the full firmware image over Airship. With `allowComplete` set, it sends COMPLETE (6) at EOF, waits
/// for DROP (7), then sends REMOVED (8) and records delivery. During a rehearsal it stops producing frames
/// at EOF so the installer can withdraw the staged image.
struct FirmwareInstallSender {
    struct Frame: Equatable { let type: Int; let payload: [UInt8] }
    enum State: Equatable { case initial, awaitingCursor, streaming, awaitingDrop, finishing, delivered, failed }

    private(set) var state = State.initial
    private(set) var sent = 0
    let size: Int
    let uuid: [UInt8]
    /// Whether COMPLETE may ever be produced. Mirrors the installer's `allowApply`; false keeps this sender from
    /// ever finishing an image.
    let allowComplete: Bool
    /// True once every byte has been handed out (EOF) while still streaming — used by the installer to tell a
    /// gated-off stall from a normal await.
    var reachedEnd: Bool { state == .streaming && sent == size }

    private let data: [UInt8]
    private let filename: String
    private var checkedAt = 0
    private var rewinds = 0
    private var responses = 0
    private var runningAdler: UInt32 = 1
    private var withdrawn = false
    private var offered = false
    /// Set once the device sends a DROP — after that a REMOVED would release the file, so `cancel()` yields nil.
    private var sawDrop = false

    init(data: [UInt8], uuid: [UInt8], filename: String, allowComplete: Bool) throws {
        guard data.count >= 2, data.count <= FirmwareOffer.maxImageBytes, uuid.count == 16,
              !filename.isEmpty, filename.utf8.count <= 64,
              filename.utf8.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 47 }) else {
            throw WakeWordFault.malformed("invalid firmware image for transfer")
        }
        self.data = data
        self.uuid = uuid
        self.filename = filename
        self.allowComplete = allowComplete
        size = data.count
    }

    /// The offer `{1: uuid, 2: size, 3: "ota", 4: filename}`.
    mutating func offer() throws -> Frame {
        guard state == .initial else { throw failure("the file was already offered") }
        state = .awaitingCursor
        offered = true
        return Frame(type: AirshipMessageType.offer,
                     payload: Wire.fieldBytes(1, uuid) + (try Wire.fieldVarint(2, Int64(size)))
                        + Wire.fieldBytes(3, Array("ota".utf8)) + Wire.fieldBytes(4, Array(filename.utf8)))
    }

    /// The next frame to send, or nil while a reply is awaited. At EOF it emits COMPLETE **only if `allowComplete`**;
    /// otherwise it yields nil forever (the gated-off path can never finish).
    mutating func next() throws -> Frame? {
        if state == .finishing {
            withdrawn = true
            state = .delivered
            return Frame(type: AirshipMessageType.removed, payload: Wire.fieldBytes(1, uuid))
        }
        guard state == .streaming else { return nil }
        if sent == size {
            // ---- APPLY GATE (sender-level backstop): no COMPLETE unless the installer opened the gate. ----
            guard allowComplete else { return nil }
            state = .awaitingDrop
            return Frame(type: AirshipMessageType.complete, payload: try cursor(sent, runningAdler))
        }
        if sent - checkedAt >= 65_536 {
            checkedAt = sent
            return Frame(type: AirshipMessageType.check, payload: try cursor(sent, runningAdler))
        }
        let end = min(size, sent + 1024)
        let chunk = Array(data[sent..<end])
        runningAdler = AirshipSender.adler(chunk, seed: runningAdler)
        sent = end
        return Frame(type: AirshipMessageType.data, payload: chunk)
    }

    /// A reply from the receiver: a correction cursor(2), or the drop(7) that must name THIS uuid and only after
    /// COMPLETE (awaitingDrop). Anything else stops the transfer.
    mutating func receive(type: Int, payload: [UInt8]) throws {
        if type == AirshipMessageType.drop { sawDrop = true }
        do {
            guard state != .initial, state != .delivered, state != .failed else {
                throw failure("a reply arrived outside the transfer")
            }
            responses += 1
            guard responses <= 1024 else { throw failure("too many replies") }
            guard type == AirshipMessageType.cursor || type == AirshipMessageType.drop else {
                throw failure("the glasses stopped the transfer (reply \(type))")
            }
            let fields = try checkedFields(payload, type: type)
            if type == AirshipMessageType.drop {
                guard fields.bytes(1) == uuid else { throw failure("the drop names another file") }
                guard state == .awaitingDrop else { throw failure("a drop before COMPLETE") }
                state = .finishing
                return
            }
            guard fields.has(2) else { throw failure("a cursor without a checksum") }
            let offset = fields.varint(1), checksum = fields.varint(2)
            guard offset >= 0, offset <= Int64(size), checksum >= 0, checksum <= Int64(UInt32.max) else {
                throw failure("an invalid cursor")
            }
            if state == .awaitingCursor {
                guard offset == 0 else { throw failure("the first cursor was not at offset 0") }
            } else {
                guard offset <= Int64(sent) else { throw failure("a cursor beyond the bytes sent") }
            }
            let prefix = AirshipSender.adler(data.prefix(Int(offset)))
            guard prefix == UInt32(checksum) else { throw failure("the partial-file checksum did not match") }
            if offset < Int64(sent) {
                rewinds += 1
                guard rewinds <= 64 else { throw failure("too many rewinds") }
            }
            sent = Int(offset)
            checkedAt = sent
            runningAdler = prefix
            state = .streaming
        } catch {
            state = .failed
            throw error
        }
    }

    /// REMOVED to withdraw an unfinished file. Nil when there is nothing to withdraw, or once a DROP arrived (then a
    /// REMOVED would release the file, so the caller closes the channel instead).
    mutating func cancel() -> Frame? {
        let wasDelivered = state == .delivered
        state = .failed
        guard offered, !withdrawn, !sawDrop, !wasDelivered else { return nil }
        withdrawn = true
        return Frame(type: AirshipMessageType.removed, payload: Wire.fieldBytes(1, uuid))
    }

    private func cursor(_ offset: Int, _ checksum: UInt32) throws -> [UInt8] {
        (try Wire.fieldVarint(1, Int64(offset))) + (try Wire.fieldVarint(2, Int64(checksum)))
    }

    private func checkedFields(_ bytes: [UInt8], type: Int) throws -> Wire.Fields {
        guard bytes.count <= 256 else { throw failure("an oversized reply") }
        var offset = 0
        var seen = Set<Int>()
        while offset < bytes.count {
            let tag = try Wire.decodeVarint(bytes, offset)
            let field = Int(tag.value >> 3), kind = tag.value & 7
            guard tag.value > 0, (1...2).contains(field), seen.insert(field).inserted else {
                throw failure("invalid reply fields")
            }
            guard type == AirshipMessageType.cursor ? kind == 0 : (field == 1 && kind == 2) else {
                throw failure("invalid reply wire type")
            }
            offset = tag.offset
            if kind == 0 {
                offset = try Wire.decodeVarint(bytes, offset).offset
            } else {
                let length = try Wire.decodeVarint(bytes, offset)
                guard length.value >= 0, length.value <= Int64(bytes.count - length.offset) else {
                    throw failure("a truncated reply")
                }
                offset = length.offset + Int(length.value)
            }
        }
        return try Wire.parse(bytes)
    }

    private func failure(_ what: String) -> WakeWordFault { .transfer("firmware image: \(what)") }
}

/// Where a firmware install is, for the app's log and lifecycle. `applying` is reported the moment the COMPLETE write
/// starts: from then on the device decides the outcome, so the app must not stop the operation for app-level reasons
/// (going to the background, …). Before it, stopping is a clean withdrawal.
public enum FirmwareInstallProgress: Sendable, Equatable {
    /// Fetching the offer and the image (no glasses yet).
    case preparing
    /// Streaming the image: the furthest file offset handed to the glasses so far (a rewind can move it back).
    case transferring(sent: Int, total: Int)
    /// COMPLETE is being (or was) sent: the glasses apply and reboot on their own.
    case applying
    /// Reconnecting after the reboot to read the running build.
    case confirming
}

/// What Meta's update server offers these glasses — the app's "check for update". A server question only: the
/// glasses are not involved.
public struct FirmwareAvailableUpdate: Sendable, Equatable {
    /// The build Meta offers (e.g. "1086324946").
    public let targetVersion: String
    /// The image size, the bytes the glasses will receive.
    public let bytes: Int
    /// The offer asks for a factory wipe — the installer refuses those (`allowPowerwash` is never set).
    public let powerwash: Bool
}

/// What a finished (or reboot-triggering) install reports.
public struct FirmwareInstallOutcome: Sendable {
    public let target: String
    public let imageBytes: Int
    /// True only if COMPLETE was authorized and sent (impossible unless `allowApply` was true).
    public let applyAuthorized: Bool
    /// The svc100 build read after the reboot, if the confirm ran.
    public let confirmedVersion: String?
}

/// Runs the firmware transfer, reboot and build confirmation as one exclusive operation on a dedicated
/// owner-key link.
///
/// Before the COMPLETE write, a failure or cancellation withdraws the file with REMOVED unless DROP already
/// arrived, closes the file channel, and stops the svc28 OTA application while the link is still usable.
/// A pre-apply link loss restarts from svc28 with a fresh install key.
///
/// Once the COMPLETE write starts, the glasses may apply and reboot. A link loss leads to build confirmation.
/// Device errors are surfaced directly. A timeout or cancellation becomes `applyOutcomeUnknown` so the caller
/// can confirm the build later. Sending a stop or retrying at that point could interrupt the apply.
public final class FirmwareOtaInstaller: Sendable {
    private let glassesID: UUID
    private let serial: String
    private let keeper = ConnectionKeeper()

    /// Requires a stored owner key and a verified identity for these glasses.
    public init(glasses: SavedGlasses) throws {
        guard try IdentityStore.ownerKey() != nil,
              let record = try IdentityStore.record(serial: glasses.serial) else { throw ReGlassError.noSavedIdentity }
        switch record.state {
        case .verified: break
        case .refused: throw ReGlassError.keyRefused
        case .pending, .unverified: throw ReGlassError.verificationIncomplete
        }
        glassesID = record.glassesID
        serial = record.serial
    }

    /// A 100 ms pause between 1024-byte DATA chunks lets the glasses drain the receive buffer as they write to flash.
    static let chunkDelay: Duration = .milliseconds(100)
    /// Upper bound on a single Airship write before the watchdog closes the transport.
    static let writeLimit: Duration = .seconds(12)
    /// Upper bound on a whole svc28 start/stop exchange (its reply wait is 40 s / 10 s) before the watchdog fires.
    static let applicationWriteLimit: Duration = .seconds(45)
    /// A dropped transfer restarts from svc28 with a fresh install key, up to this many attempts.
    static let maxAttempts = 3

    /// Pass the selected version as `expectedTarget`. Set `allowApply: true` only after the wearer confirms it.
    /// A rehearsal throws `FirmwareInstallFault.applyGateClosed` after staging and withdraws the image.
    public func performRealFirmwareInstall(account: MetaAccount, expectedTarget: String, allowApply: Bool = false,
                                           allowPowerwash: Bool = false,
                                           note: @escaping @Sendable (String) -> Void = { _ in },
                                           progress: @escaping @Sendable (FirmwareInstallProgress) -> Void = { _ in })
        async throws -> FirmwareInstallOutcome {
        try await FirmwareOperation.exclusive {
            try await install(account: account, expectedTarget: expectedTarget, allowApply: allowApply,
                              allowPowerwash: allowPowerwash, note: note, progress: progress)
        }
    }

    private func install(account: MetaAccount, expectedTarget: String, allowApply: Bool, allowPowerwash: Bool,
                         note: @escaping @Sendable (String) -> Void,
                         progress: @escaping @Sendable (FirmwareInstallProgress) -> Void)
        async throws -> FirmwareInstallOutcome {
        note("Firmware install: begin (allowApply=\(allowApply), allowPowerwash=\(allowPowerwash))")
        progress(.preparing)
        guard let key = try IdentityStore.ownerKey() else { throw ReGlassError.noSavedIdentity }

        // 1) Fetch the server offer and verify the image against its checksum before connecting to the glasses.
        let token = try await account.pairingToken()
        guard token.universe == "ar", account.status == .signedIn else { throw ReGlassError.signInRequired }
        let offer = try await FirmwareOffer.fetch(token: token.value, serial: serial)
        guard offer.targetVersion == expectedTarget else {
            let fault = FirmwareInstallFault.offerChanged(offer.targetVersion)
            kitLog("firmware", fault.description)
            throw fault
        }
        kitLog("firmware", "install offer: \(offer.logSummary)")
        guard offer.fileChecksum != nil else { throw FirmwareInstallFault.planInvalid("no image checksum") }
        let image = try await FirmwareImageDownload.fetch(offer)
        defer { FirmwareImageDownload.discard(image) }
        note("offer: target \(offer.targetVersion) from \(offer.baseVersion), \(offer.fileSize) bytes, payload "
             + "\(offer.payloadSize) at \(offer.payloadOffset), \(offer.metaHeaders.isEmpty ? "no" : "with") headers"
             + "\(offer.powerwash ? ", POWERWASH" : "")")

        // 2) The transfer, with a NON-RESUMABLE retry: a fresh install key + svc28 start per attempt. A mid-transfer
        //    drop on any attempt but the last restarts from svc28; on the last it propagates. With `allowApply`
        //    false the run throws `.applyGateClosed` once the whole image is staged.
        var transfer: TransferResult?
        for attempt in 1...Self.maxAttempts {
            let plan = try FirmwareInstallPlan.build(offer: offer, image: image.bytes, fileUuid: Self.freshUUIDBytes(),
                                                     key: ResourceOta.Key(), allowPowerwash: allowPowerwash)
            do {
                transfer = try await runTransfer(plan: plan, key: key, allowApply: allowApply, progress: progress)
                break
            } catch FirmwareInstallFault.midTransferDrop where attempt < Self.maxAttempts {
                note("mid-transfer drop on attempt \(attempt); restarting from svc28 with a fresh key")
                try await Task.sleep(for: Self.retryPause)
            }
        }
        guard let transfer else { throw FirmwareInstallFault.midTransferDrop }

        // 3) Reboot-aware confirmation of the svc100 build, riding the glasses' own reboot/reconnect. It starts only
        //    after the transfer link is gone. Retry if the glasses still report the previous build.
        progress(.confirming)
        let confirmation = FirmwareConfirmation(glassesID: glassesID, serial: serial, key: key,
                                                target: offer.targetVersion, previous: transfer.previousBuild)
        let confirmedVersion: String
        switch try await confirmation.confirm(attempts: Self.maxAttempts) {
        case .matched(let version):
            confirmedVersion = version
            note("post-reboot build confirmed: \(version)")
        case .unchanged(let version), .mismatch(let version):
            throw FirmwareInstallFault.confirmMismatch(got: version, want: offer.targetVersion)
        case .unconfirmed(let lastSeen):
            throw FirmwareInstallFault.applyOutcomeUnknown("last read build \(lastSeen), then no answer")
        }

        note("Firmware install: done")
        return FirmwareInstallOutcome(target: offer.targetVersion, imageBytes: image.bytes.count,
                                      applyAuthorized: true, confirmedVersion: confirmedVersion)
    }

    private struct TransferResult { let previousBuild: String? }

    /// One transfer attempt on a fresh owner-key link (current firmware, so the default wake-word build policy is
    /// correct here). Returns once the apply was authorized and the link has gone down for the reboot (or the device
    /// reported REBOOT/COMPLETE), with the build the glasses reported before the apply. Throws `.midTransferDrop`
    /// for a pre-apply link loss so the caller can restart from svc28.
    ///
    /// Manages svc28 directly so cleanup sends a stop only before the COMPLETE write. A stop during apply would
    /// race the glasses' reboot and derail confirmation.
    private func runTransfer(plan: FirmwareInstallPlan, key: OwnerKey, allowApply: Bool,
                             progress: @escaping @Sendable (FirmwareInstallProgress) -> Void)
        async throws -> TransferResult {
        let requiredSpaceMB = FirmwareOta.requiredSpaceMB(totalBytes: plan.offer.fileSize)
        keeper.hold(glassesID)
        defer { keeper.release() }
        let link = WakeWordLink(glasses: glassesID, serial: serial, key: key, otaStart: {
            try FirmwareOta.startApplication(attempt: plan.key.attempt, requiredSpaceMB: requiredSpaceMB)
        })
        await link.start()
        let close: @Sendable () -> Void = { [weak link] in link?.closeTransport() }
        var conversation: FirmwareInstallConversation?
        var ready: WakeWordLink.Ready?
        var started = false
        do {
            let usable = try await link.waitUntilUsable(timeout: Self.connectLimit)
            ready = usable
            let previousBuild = link.peerInfo(for: usable).flatMap {
                WakeWordCatalog.firmwareVersion(fromBuild: $0.firmware)
            }
            // ReGlass's battery floor, BEFORE the ~20-minute transfer: the glasses report their battery on their own
            // right after the READY subscription, so wait briefly for that report instead of asking for one.
            let batteryDeadline = ContinuousClock.now + Self.batteryWait
            while link.battery(for: usable) == nil, ContinuousClock.now < batteryDeadline {
                guard link.isCurrent(usable.generation) else { throw WakeWordFault.connectionChanged }
                try await Task.sleep(for: .milliseconds(100))
            }
            let battery = link.battery(for: usable)
            kitLog("firmware", "glasses battery before the transfer: \(battery.map { "\($0) %" } ?? "not reported")")
            try FirmwareBatteryFloor.check(battery)
            let current = FirmwareInstallConversation(
                mux: usable.mux, plan: plan, allowApply: allowApply,
                isCurrent: link.currentCheck(usable.generation),
                battery: { [weak link] in link?.battery(for: usable) },
                closeTransport: close, progress: progress)
            conversation = current
            link.attachFirmware(current)

            try await FirmwareOperation.watched(Self.applicationWriteLimit, "the OTA application start", close: close) {
                try await link.startOtaApplication(usable)
            }
            // Ownership is recorded the moment the start is acknowledged — before the (cancellable) readiness pause —
            // so any failure from here on stops the application we started.
            started = true
            try await Task.sleep(for: WakeWordLink.otaReadyPause)
            try await current.run()
            link.attachFirmware(nil)
            await link.stop()
            return TransferResult(previousBuild: previousBuild)
        } catch {
            link.attachFirmware(nil)
            let applyMayHaveStarted = await conversation?.applyMayHaveStarted ?? false
            if !applyMayHaveStarted, started, let usable = ready, link.isCurrent(usable.generation) {
                // Pre-apply abort: the conversation already withdrew the file; stop the OTA application, bounded. It
                // runs in its own task so a CANCELLED caller still sends the stop (`setOtaApplication` checks
                // cancellation first) — the same reason `withOtaApplication` cleans up in a separate task.
                let cleanup = Task {
                    try await FirmwareOperation.watched(Self.applicationWriteLimit, "the OTA application stop",
                                                        close: close) {
                        try await link.stopOtaApplication(usable)
                    }
                }
                do { try await cleanup.value } catch { kitLog("firmware", "OTA application stop not confirmed") }
            }
            await link.stop()
            if !applyMayHaveStarted, ready != nil, FirmwareOperation.isLinkLoss(error) {
                throw FirmwareInstallFault.midTransferDrop
            }
            throw error
        }
    }

    // MARK: Checking for an update (no glasses)

    /// Asks Meta's update server what firmware it offers the glasses with `serial` — the same constellation query an
    /// install starts with. Never touches the glasses. Throws `signInRequired` without a Meta sign-in.
    public static func availableUpdate(account: MetaAccount, serial: String) async throws -> FirmwareAvailableUpdate {
        let token = try await account.pairingToken()
        guard token.universe == "ar", account.status == .signedIn else { throw ReGlassError.signInRequired }
        let offer = try await FirmwareOffer.fetch(token: token.value, serial: serial)
        kitLog("firmware", "update check: \(offer.logSummary)")
        return FirmwareAvailableUpdate(targetVersion: offer.targetVersion, bytes: offer.fileSize,
                                       powerwash: offer.powerwash)
    }

    /// The plain build number inside a glasses build string ("Meta/orca/orca:none/1082194281/none:user/none" →
    /// "1082194281"), or nil when it is not a well-formed orca build.
    public static func version(fromBuild build: String) -> String? {
        WakeWordCatalog.firmwareVersion(fromBuild: build)
    }

    /// ReGlass's battery floor for an update, so the app can say it before starting.
    public static var minimumBatteryPercent: Int { FirmwareBatteryFloor.minimumPercent }

    private static func freshUUIDBytes() -> [UInt8] { withUnsafeBytes(of: UUID().uuid) { Array($0) } }

    private static let connectLimit: Duration = .seconds(90)
    private static let retryPause: Duration = .seconds(5)
    /// How long to wait for the glasses' own battery report after READY before refusing as `.batteryUnknown`.
    private static let batteryWait: Duration = .seconds(10)
}

/// Drives svc29 and svc20 on a `WakeWordLink` through the reboot. The session delivers replies to this actor
/// between sends. This conversation is the only writer of a firmware COMPLETE frame.
///
/// An explicit phase machine that only moves forward. APPLY/REBOOT/COMPLETE progress is legitimate ONLY once the
/// apply was authorized; any earlier it is a hard fault. The FIRST failure recorded is the one thrown, and it is
/// re-checked after every wait and before every transition and return.
actor FirmwareInstallConversation {
    enum Phase: Int, Comparable {
        /// INSTALL sent, waiting for the device to ask for the image.
        case installing
        /// Offering/streaming the image. No COMPLETE has been sent.
        case transferring
        /// The whole image is staged and the gate is open: COMPLETE may now be
        /// produced. (`completeAttempted` marks the moment its write starts — from then on: no stop, no retry.)
        case authorized
        /// COMPLETE → DROP → REMOVED done; svc29 torn down; waiting for REBOOT or the link to drop.
        case delivered

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let mux: DataXMultiplexer
    private let plan: FirmwareInstallPlan
    private let allowApply: Bool
    private let isCurrent: @Sendable () -> Bool
    /// The glasses' battery as they last reported it on this attempt (passive), for the floor check before COMPLETE.
    private let battery: @Sendable () -> Int?
    private let closeTransport: @Sendable () -> Void
    private let progress: @Sendable (FirmwareInstallProgress) -> Void
    /// The offset last reported as `.transferring` (every `progressStep` bytes and at EOF) and last logged.
    private var reportedAt = 0
    private var loggedAt = 0

    private(set) var phase = Phase.installing
    private var sawSend = false
    private var sawReboot = false
    private var terminalComplete = false
    private var failure: Error?
    private var sender: FirmwareInstallSender?
    /// The transfer channel. It stays set through teardown, so a late DROP is still observed while the withdrawal
    /// goes out; `withdrawn` makes the withdrawal idempotent.
    private var channel: Int?
    private var withdrawn = false
    private var firstCursor = false
    /// Set immediately BEFORE the COMPLETE write: from then on the frame may have reached the device.
    private var completeAttempted = false

    /// Whether a COMPLETE may have reached the device (its write was started). Once true: never a stop, never a
    /// retry — the outcome is decided by the device and read back by the confirmation.
    var applyMayHaveStarted: Bool { completeAttempted }

    init(mux: DataXMultiplexer, plan: FirmwareInstallPlan, allowApply: Bool,
         isCurrent: @escaping @Sendable () -> Bool,
         battery: @escaping @Sendable () -> Int?,
         closeTransport: @escaping @Sendable () -> Void,
         progress: @escaping @Sendable (FirmwareInstallProgress) -> Void = { _ in }) {
        self.mux = mux
        self.progress = progress
        self.plan = plan
        self.allowApply = allowApply
        self.isCurrent = isCurrent
        self.battery = battery
        self.closeTransport = closeTransport
    }

    /// Records the first failure only; later failures never mask the original cause.
    private func fail(_ error: Error) {
        if failure == nil { failure = error }
    }

    // MARK: Replies (from the session's pump)

    func receiveOta(type: Int, payload: [UInt8], from source: DataXMultiplexer) {
        guard source === mux, isCurrent(), failure == nil else { return }
        kitLog("firmware", "svc29 from the glasses: type \(type), \(payload.count) bytes")
        do {
            guard let reply = try FirmwareOta.reply(type: type, payload: payload, key: plan.key) else { return }
            switch reply {
            case let .fileStatus(uuid, status):
                guard uuid == plan.fileUuid else { return }
                switch status {
                case .send, .waiting: sawSend = true
                case .have:
                    // After the COMPLETE write, HAVE is the glasses confirming they hold the delivered image — the
                    // expected answer (seen on hardware right after DROP → REMOVED), never a refusal. Meta's companion
                    // doesn't act on file status at all. Only BEFORE the transfer is a HAVE for a fresh id wrong.
                    guard completeAttempted else {
                        throw FirmwareInstallFault.deviceRefused("unexpected HAVE for a fresh image id")
                    }
                    kitLog("firmware", "the glasses confirm they hold the delivered image (HAVE)")
                case .unknown: throw FirmwareInstallFault.deviceRefused("unknown file status")
                }
            case let .progress(stage, percent):
                let shown = percent.map { String(format: " (%.3f)", $0) } ?? ""
                kitLog("firmware", "install progress: stage \(stage)\(shown) [phase \(phase)]")
                switch stage {
                case FirmwareOta.Stage.apply, FirmwareOta.Stage.reboot, FirmwareOta.Stage.complete:
                    // The device-driven apply path. Legitimate ONLY after an authorized COMPLETE.
                    guard allowApply, completeAttempted else { throw FirmwareInstallFault.unexpectedApply }
                    if stage == FirmwareOta.Stage.reboot { sawReboot = true }
                    if stage == FirmwareOta.Stage.complete { terminalComplete = true }
                case FirmwareOta.Stage.stopped:
                    throw FirmwareInstallFault.deviceRefused("the device stopped the install (stage STOPPED)")
                case FirmwareOta.Stage.download:
                    // The Audio glasses have no Wi-Fi and the request carries no URL: a device-side download is not
                    // part of this install. Before the apply it is a refusal; after it, only logged.
                    guard completeAttempted else {
                        throw FirmwareInstallFault.deviceRefused("unexpected DOWNLOAD stage (no URL was sent)")
                    }
                default:
                    break                                       // TRANSFER/STARTUP/UNKNOWN are informational.
                }
            case let .error(detail):
                throw FirmwareInstallFault.deviceRefused(detail.description)
            }
        } catch {
            fail(error)
        }
    }

    func receiveAirship(_ message: DataXMessage, from source: DataXMultiplexer) {
        guard source === mux, isCurrent(), let channel, sender != nil,
              message.info.channelId == DataXMultiplexer.mirror(channel) else { return }
        do {
            try sender?.receive(type: message.info.messageType, payload: message.payload)
            // Any correction cursor after the authorization (a rewind, before or after a COMPLETE attempt) revokes
            // it: the sender streams from the rewound offset and is authorized again when it reaches EOF.
            if message.info.messageType == AirshipMessageType.cursor, phase == .authorized {
                kitLog("firmware", "cursor after authorization (rewind to \(sender?.sent ?? 0)); re-authorizing at EOF")
                phase = .transferring
            }
            if sender?.state == .streaming, !firstCursor {
                firstCursor = true
                kitLog("firmware", "first cursor exchanged at offset \(sender?.sent ?? 0)")
            }
        } catch {
            fail(error)
        }
    }

    func receiveStatus(service: Int, channel statusChannel: Int, status: Int) {
        guard isCurrent(), failure == nil else { return }
        if service == DataXService.airship {
            guard let channel, statusChannel == DataXMultiplexer.mirror(channel) else { return }
            fail(FirmwareInstallFault.deviceRefused(String(format: "svc20 status 0x%04x", status)))
        } else if service == DataXService.resourceOta {
            fail(FirmwareInstallFault.deviceRefused(String(format: "svc29 status 0x%04x", status)))
        }
    }

    // MARK: Run

    /// Drives install → transfer → (gated) COMPLETE → DROP → REMOVED → apply/reboot. Returns once the apply was
    /// authorized and the device rebooted (link dropped, or REBOOT/COMPLETE reported).
    ///
    /// Throws `.applyGateClosed` (expected while `allowApply` is false) once the whole image is staged. On any
    /// failure BEFORE the COMPLETE write it first withdraws the file and closes its channel; after it, it touches
    /// nothing — a device ERROR is rethrown, other interruptions become `.applyOutcomeUnknown`, and a lost
    /// link is the expected reboot (returns normally).
    func run() async throws {
        do {
            try await runPhases()
        } catch {
            if completeAttempted {
                if FirmwareOperation.isLinkLoss(error), failure == nil {
                    kitLog("firmware", "link dropped after the COMPLETE write began — handing over to the build "
                       + "confirmation (an unverified reboot, not proof of one)")
                    return
                }
                if let failure { throw failure }
                if case FirmwareInstallFault.deviceRefused = error { throw error }
                throw FirmwareInstallFault.applyOutcomeUnknown(String(describing: error))
            }
            // Capture the cause BEFORE cleanup, so an error the withdrawal itself provokes can't replace it (or change
            // the retry classification). The withdrawal runs in its own task: a cancelled caller must still withdraw.
            let primary = failure ?? error
            await Task { await self.withdraw() }.value
            throw primary
        }
    }

    private func runPhases() async throws {
        try checkCurrent()
        // 1) Request a primary-image install with the image supplied over Airship.
        let request = try FirmwareOta.install(key: plan.key, offer: plan.offer, fileUuid: plan.fileUuid)
        try await FirmwareOperation.watched(FirmwareOtaInstaller.writeLimit, "the install request",
                                            close: closeTransport) {
            try await mux.sendOnService(DataXService.resourceOta, ResourceOtaMessageType.install, request)
        }
        kitLog("firmware", "install sent: target \(plan.offer.targetVersion), \(plan.offer.fileSize) bytes")

        // 2) Wait for SEND/WAITING (HAVE or an error surfaces through `checkCurrent`).
        let sendDeadline = ContinuousClock.now + Self.fileStatusLimit
        while !sawSend {
            try checkCurrent()
            guard ContinuousClock.now < sendDeadline else {
                throw FirmwareInstallFault.timedOut("the device to ask for the image")
            }
            try await Task.sleep(for: Self.poll)
        }
        try checkCurrent()
        phase = .transferring

        // 3) Offer the whole image and exchange the first cursor. `allowComplete` tracks the apply gate.
        let filename = "firmware-\(plan.offer.targetVersion)"
        var sender = try FirmwareInstallSender(data: plan.image, uuid: plan.fileUuid, filename: filename,
                                               allowComplete: allowApply)
        let airshipChannel = await mux.openChannel(DataXService.airship)
        channel = airshipChannel
        let offerFrame = try sender.offer()
        self.sender = sender
        try checkCurrent()
        try await sendWatched(airshipChannel, offerFrame, serviceId: DataXService.airship)
        let cursorDeadline = ContinuousClock.now + Self.replyLimit
        while self.sender?.state == .awaitingCursor {
            try checkCurrent()
            guard ContinuousClock.now < cursorDeadline else { throw FirmwareInstallFault.timedOut("the first cursor") }
            try await Task.sleep(for: Self.poll)
        }
        try checkCurrent()

        // 4) Transfer the WHOLE image with 100 ms pacing; the ONLY COMPLETE emission is gated below.
        var deadline = ContinuousClock.now + Self.replyLimit
        while self.sender?.state != .delivered {
            try checkCurrent()
            guard ContinuousClock.now < deadline else {
                throw FirmwareInstallFault.timedOut("a cursor at \(self.sender?.sent ?? 0) bytes")
            }
            if let current = self.sender, current.reachedEnd, phase == .transferring {
                // Rehearsal stops once the whole image is staged. An authorized install can proceed to COMPLETE.
                guard current.allowComplete, allowApply else { throw FirmwareInstallFault.applyGateClosed }
                phase = .authorized
            }
            if let frame = try nextFrame() {
                if frame.type == AirshipMessageType.complete {
                    // COMPLETE (6) lets the glasses apply and reboot on their own. Send it only after the full
                    // image is staged and `allowApply` is true.
                    guard allowApply, phase == .authorized else { throw FirmwareInstallFault.applyGateClosed }
                    // ReGlass's battery floor, on the glasses' latest own report. Still before the COMPLETE write, so
                    // a refusal here is a clean pre-apply withdrawal.
                    try FirmwareBatteryFloor.check(battery())
                    kitLog("firmware", "APPLY AUTHORIZED: sending COMPLETE for the full image "
                           + "(\(self.sender?.size ?? 0) bytes, battery \(battery().map { "\($0) %" } ?? "?")); "
                           + "the device will apply and reboot")
                    completeAttempted = true
                    progress(.applying)
                }
                try await sendWatched(airshipChannel, frame)
                if frame.type == AirshipMessageType.data {
                    reportTransfer()
                    try await Task.sleep(for: FirmwareOtaInstaller.chunkDelay)
                }
                deadline = ContinuousClock.now + Self.replyLimit
            } else {
                try await Task.sleep(for: Self.poll)
            }
        }
        try checkCurrent()
        phase = .delivered
        kitLog("firmware", "image delivered (COMPLETE → DROP → REMOVED); svc29 stays open through the apply")

        // 5) Keep svc29 open for apply errors until REBOOT or COMPLETE arrives, then close only that channel.
        //    If the link drops first, the build check determines whether the glasses rebooted into the update.
        let applyDeadline = ContinuousClock.now + Self.applyLimit
        while !sawReboot, !terminalComplete {
            try checkCurrent()
            guard ContinuousClock.now < applyDeadline else { throw FirmwareInstallFault.timedOut("the apply/reboot") }
            try await Task.sleep(for: Self.poll)
        }
        if let failure { throw failure }
        kitLog("firmware", "device reported \(sawReboot ? "REBOOT" : "COMPLETE"); closing svc29 (Meta's teardown)")
        if isCurrent() {
            try? await FirmwareOperation.watched(FirmwareOtaInstaller.writeLimit, "the svc29 close",
                                                 close: closeTransport) {
                try await mux.closeServiceChannel(DataXService.resourceOta)
            }
        }
    }

    /// Reports the streamed offset to the app every `progressStep` bytes and at EOF, and logs it every `logStep`
    /// (never on the wire). A rewind moves `sent` back; reporting resumes once it passes the last report again.
    private func reportTransfer() {
        guard let sent = sender?.sent else { return }
        let atEnd = sent == plan.image.count && reportedAt < sent
        guard atEnd || sent >= reportedAt + Self.progressStep else { return }
        reportedAt = sent
        if atEnd || sent >= loggedAt + Self.logStep {
            loggedAt = sent
            kitLog("firmware", "streamed \(sent) of \(plan.image.count) bytes")
        }
        progress(.transferring(sent: sent, total: plan.image.count))
    }

    private func nextFrame() throws -> FirmwareInstallSender.Frame? {
        guard var current = sender else { return nil }
        let frame = try current.next()
        sender = current
        return frame
    }

    /// Sends one Airship frame under the write watchdog.
    private func sendWatched(_ channel: Int, _ frame: FirmwareInstallSender.Frame, serviceId: Int? = nil) async throws {
        try await FirmwareOperation.watched(FirmwareOtaInstaller.writeLimit, "an Airship write",
                                            close: closeTransport) {
            try await mux.send(channel, frame.payload, messageType: frame.type, serviceId: serviceId)
        }
    }

    /// Pre-apply abort: withdraw the file (REMOVED — never after a DROP, where it would be a release) and close its
    /// channel, each write bounded by the watchdog. Idempotent; never throws.
    private func withdraw() async {
        guard let channel, !withdrawn else { return }
        withdrawn = true
        if var current = sender {
            let frame = current.cancel()
            sender = current
            if let frame, isCurrent() {
                do {
                    try await sendWatched(channel, frame)
                    kitLog("firmware", "withdrew the image (REMOVED)")
                } catch {
                    kitLog("firmware", "could not send the withdrawal; closing its channel")
                }
            }
        }
        if isCurrent() {
            try? await FirmwareOperation.watched(FirmwareOtaInstaller.writeLimit, "the transfer channel close",
                                                 close: closeTransport) {
                try await mux.closeLocalChannel(channel)
            }
        }
    }

    /// The first recorded failure wins over a lost link, which wins over nothing. Cancellation is checked first.
    private func checkCurrent() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard isCurrent() else { throw WakeWordFault.connectionChanged }
    }

    private static let fileStatusLimit: Duration = .seconds(90)
    private static let replyLimit: Duration = .seconds(15)
    private static let applyLimit: Duration = .seconds(300)
    private static let poll: Duration = .milliseconds(50)
    private static let progressStep = 16 * 1024
    private static let logStep = 256 * 1024
}
