import Foundation

/// The link one wake word install runs on: its own owner-key session (the live connection has let go first), with
/// handlers for svc20, svc28 and svc29. It is usable once READY, owner trust in both directions, and the svc100
/// serial matching the saved glasses all hold on the same attempt, on the verified firmware.
///
/// "Current" means that same attempt is still up. Any drop or reconnect makes every later wait fail rather than
/// carry on over a different link.
final class WakeWordLink: Sendable {
    /// The multiplexer of the attempt that became usable, and that attempt's number.
    struct Ready: Sendable {
        let mux: DataXMultiplexer
        let generation: Int
    }

    private struct State {
        var generation = 0
        var linkUp = false
        var mux: DataXMultiplexer?
        var muxGeneration = -1
        var info: PeerDeviceInfo?
        var lastFailure: ReGlassError?
        var stopped = false
        var events: Task<Void, Never>?
        var transfer: WakeWordTransfer?
        /// Active firmware installation conversation.
        var firmware: FirmwareInstallConversation?
        var inventory: OneShot<[UInt8]>?
        var application: (response: Int, result: OneShot<[UInt8]>)?
        /// The glasses' battery percent as they last reported it on this attempt — read PASSIVELY from the status
        /// pushes the READY subscription already brings (nothing is ever requested for it). Firmware reads it.
        var battery: (generation: Int, percent: Int)?
    }

    private let session: GlassesLinkSession
    private let serial: String
    private let state: Locked<State>
    private let usable = OneShot<Ready>()
    /// An injected svc28 start payload (firmware), or nil to keep the resource default. Only `setOtaApplication`
    /// reads it, and only on a start; a stop is always the shared resource stop.
    private let otaStart: (@Sendable () throws -> [UInt8])?
    /// Decides whether a reported firmware build makes the link usable. By default, `WakeWordCatalog.isSupported`
    /// accepts any well-formed Audio build. Firmware confirmation can supply its own policy for the new build.
    private let firmwareAccepts: (@Sendable (String?) -> Bool)?

    init(glasses: UUID, serial: String, key: OwnerKey, otaStart: (@Sendable () throws -> [UInt8])? = nil,
         firmwareAccepts: (@Sendable (String?) -> Bool)? = nil) {
        let state = Locked(State())
        self.state = state
        self.serial = serial
        self.otaStart = otaStart
        self.firmwareAccepts = firmwareAccepts
        let handlers: [Int: ServiceHandler] = [
            DataXService.resourceOta: { message, mux in
                if let firmware = state.current.firmware {
                    await firmware.receiveOta(type: message.info.messageType, payload: message.payload, from: mux)
                    return
                }
                guard let transfer = state.current.transfer else { return }
                await transfer.receiveOta(type: message.info.messageType, payload: message.payload, from: mux)
            },
            DataXService.airship: { message, mux in
                if let firmware = state.current.firmware {
                    await firmware.receiveAirship(message, from: mux)
                } else if let transfer = state.current.transfer {
                    await transfer.receiveAirship(message, from: mux)
                }
                // The glasses offer files of their own on channels they open; decline them so their queue moves on.
                if message.info.channelId & DataXChannel.originatorBit != 0,
                   let frame = AirshipSender.declineOffer(type: message.info.messageType, payload: message.payload) {
                    try await mux.send(DataXMultiplexer.mirror(message.info.channelId), frame.payload,
                                       messageType: frame.type)
                }
            },
            DataXService.status: { message, mux in
                guard message.payload.count <= 4096 else { return }
                // Battery, passively: a DeviceState snapshot/push (2005…) the glasses send on their own after the
                // READY subscription. Recorded for this attempt's multiplexer only; never answers a wait below
                // (svc28 replies are 2001/2003), so every other path behaves exactly as before.
                if DeviceStateReading.isDeviceState(message.info.messageType) {
                    if let percent = (try? DeviceStateReading.decode(message.payload))?.batteryPercent {
                        state.withLock { if $0.mux === mux { $0.battery = ($0.generation, percent) } }
                    }
                    return
                }
                guard let wait = state.current.application, message.info.messageType == wait.response else { return }
                wait.result.resolve(.success(message.payload))
            },
        ]
        session = GlassesLinkSession(transport: { L2CAPTransport(glasses: glasses) }, trust: ownerTrustHook(key),
                                     handlers: handlers)
    }

    func start() async {
        await session.start()
        let session = session
        let task = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        state.withLock { $0.events = task }
    }

    /// Lets go of the glasses and returns once the link is closed.
    func stop() async {
        let events = state.withLock { state -> Task<Void, Never>? in
            state.stopped = true
            return state.events
        }
        failWaits(.connectionChanged)
        usable.resolve(.failure(WakeWordFault.connectionChanged))
        await session.stop()
        await events?.value
    }

    /// Waits until the link is usable. Throws `.keyRefused`, `.serialMismatch`, `.verificationIncomplete`,
    /// `unsupportedFirmware`, or the last connect failure (`.noAnswer` when none) once `timeout` passes.
    func waitUntilUsable(timeout: Duration) async throws -> Ready {
        let usable = usable
        do {
            return try await withTimeout(timeout, "the glasses") { try await usable.value() }
        } catch ReGlassError.timedOut {
            throw state.current.lastFailure ?? ReGlassError.noAnswer
        }
    }

    func isCurrent(_ generation: Int) -> Bool {
        Self.isCurrent(state, generation)
    }

    private static func isCurrent(_ state: Locked<State>, _ generation: Int) -> Bool {
        state.withLock { !$0.stopped && $0.linkUp && $0.generation == generation && $0.muxGeneration == generation }
    }

    /// A check the transfer can call from anywhere.
    func currentCheck(_ generation: Int) -> @Sendable () -> Bool {
        let state = state
        return { Self.isCurrent(state, generation) }
    }

    func attach(_ transfer: WakeWordTransfer?) {
        state.withLock { $0.transfer = transfer }
    }

    /// Routes svc29 and svc20 messages and status refusals to the active firmware installer.
    func attachFirmware(_ conversation: FirmwareInstallConversation?) {
        state.withLock { $0.firmware = conversation }
    }

    /// The glasses' svc100 build info (firmware build in field 1) for exactly the attempt `ready` names, or nil if
    /// that attempt is no longer current. The firmware paths read the running MCU build from here.
    func peerInfo(for ready: Ready) -> PeerDeviceInfo? {
        state.withLock { state in
            guard !state.stopped, state.linkUp, state.generation == ready.generation,
                  state.muxGeneration == ready.generation else { return nil }
            return state.info
        }
    }

    /// The glasses' battery percent as last reported on exactly the attempt `ready` names (passive — see `State`),
    /// or nil when none arrived yet or the attempt is gone.
    func battery(for ready: Ready) -> Int? {
        state.withLock { state in
            guard !state.stopped, state.linkUp, state.generation == ready.generation,
                  state.muxGeneration == ready.generation, let battery = state.battery,
                  battery.generation == ready.generation else { return nil }
            return battery.percent
        }
    }

    /// Force the live transport closed. A blocked L2CAP write cannot be unstuck by task cancellation
    /// (`L2CAPPipe` has no write deadline), so the firmware write watchdog calls this to resume a stuck writer
    /// with `.linkLost` and tear the attempt down. Safe to call when nothing is connected.
    func closeTransport() {
        session.closeTransport()
    }

    // MARK: svc22, the installed resources

    /// Asks svc22 for the device info (empty request; this MCU does not read its body) and decodes the resource
    /// lists from the answer. The request goes through the session's command queue, after the READY requests.
    func readInventory(_ ready: Ready) async throws -> ResourceInventory {
        let waiter = OneShot<[UInt8]>()
        try state.withLock { state in
            guard state.inventory == nil else { throw WakeWordFault.malformed("a resource read is already running") }
            state.inventory = waiter
        }
        defer { state.withLock { if $0.inventory === waiter { $0.inventory = nil } } }
        guard isCurrent(ready.generation) else { throw WakeWordFault.connectionChanged }
        let check = currentCheck(ready.generation)
        session.submit { mux in
            guard check(), mux === ready.mux else {
                waiter.resolve(.failure(WakeWordFault.connectionChanged))
                return
            }
            do {
                try await mux.sendOnService(DataXService.deviceInfo, DeviceInfoMessageType.deviceInfoRequest, [])
            } catch {
                waiter.resolve(.failure(WakeWordFault.connectionChanged))
            }
        }
        let payload: [UInt8]
        do {
            payload = try await withTimeout(Self.inventoryLimit, "the resource list") { try await waiter.value() }
        } catch ReGlassError.timedOut(let what) {
            throw WakeWordFault.timedOut(what)
        }
        guard isCurrent(ready.generation) else { throw WakeWordFault.connectionChanged }
        return try ResourceInventory.decode(payload)
    }

    // MARK: svc28, the OTA application

    /// Starts the glasses' resource OTA application, runs `work`, and stops it again. Only an application this run
    /// started is stopped: "already started" is never taken over. A failure inside stops it within 10 s, bounded,
    /// and rethrows the original error.
    func withOtaApplication(_ ready: Ready, _ work: () async throws -> Void) async throws {
        try await setOtaApplication(running: true, ready, timeout: Self.applicationLimit)
        do {
            // The start callback queues the OTA readiness before it answers; let that worker run before svc29.
            try await Task.sleep(for: .milliseconds(500))
            try await work()
            try await setOtaApplication(running: false, ready, timeout: Self.applicationLimit)
        } catch {
            if isCurrent(ready.generation) {
                let cleanup = Task {
                    try await self.setOtaApplication(running: false, ready, timeout: Self.applicationCleanupLimit)
                }
                do { try await cleanup.value } catch { kitLog("wakeword", "OTA application stop not confirmed") }
            }
            throw error
        }
    }

    /// Starts the OTA application on its own (the same start `withOtaApplication` sends), for a firmware caller that
    /// must decide per phase whether a stop follows. Returns once the start is ACKNOWLEDGED, so the caller can record
    /// ownership before anything else can fail; the caller then pauses `otaReadyPause` before svc29 (the start
    /// callback queues the OTA readiness before it answers). `withOtaApplication` is unchanged for every other path.
    func startOtaApplication(_ ready: Ready) async throws {
        try await setOtaApplication(running: true, ready, timeout: Self.applicationLimit)
    }

    /// Stops the OTA application (bounded by `timeout`). The firmware installer calls this ONLY while no COMPLETE can
    /// have reached the device; after it, Meta never sends a stop (the device applies and reboots on its own).
    func stopOtaApplication(_ ready: Ready, timeout: Duration = WakeWordLink.applicationCleanupLimit) async throws {
        try await setOtaApplication(running: false, ready, timeout: timeout)
    }

    /// The pause `withOtaApplication` takes between an acknowledged start and the first svc29 message.
    static let otaReadyPause: Duration = .milliseconds(500)

    private func setOtaApplication(running: Bool, _ ready: Ready, timeout: Duration) async throws {
        try Task.checkCancellation()
        guard isCurrent(ready.generation) else { throw WakeWordFault.connectionChanged }
        let response = running ? AppManagerMessageType.startAppResponse : AppManagerMessageType.stopAppResponse
        let waiter = OneShot<[UInt8]>()
        state.withLock { $0.application = (response, waiter) }
        defer { state.withLock { if $0.application?.result === waiter { $0.application = nil } } }
        let payload: [UInt8]
        if running {
            // The firmware installer supplies its own start via `otaStart`.
            payload = try otaStart?() ?? ResourceOta.startApplication(attempt: UUID().uuidString.lowercased())
        } else {
            payload = ResourceOta.stopApplication()
        }
        kitLog("wakeword", running ? "starting the OTA application" : "stopping the OTA application")
        try await ready.mux.sendOnService(DataXService.status,
                                          running ? AppManagerMessageType.startApp : AppManagerMessageType.stopApp,
                                          payload)
        let answer: [UInt8]
        do {
            answer = try await withTimeout(timeout, "the OTA application") { try await waiter.value() }
        } catch ReGlassError.timedOut {
            throw WakeWordFault.timedOut("the OTA application to \(running ? "start" : "stop")")
        }
        let code = try ResourceOta.applicationResult(answer)
        kitLog("wakeword", "OTA application \(running ? "start" : "stop") answered \(code)")
        // A stop may find it already ended by the completion (11); a start that finds one running is not ours.
        guard code == 1 || (!running && code == 11) else {
            throw WakeWordFault.application(code: code, starting: running)
        }
    }

    // MARK: Events

    private func handle(_ event: LinkEvent) async {
        switch event {
        case .state(.connecting, _):
            state.withLock { state in
                state.generation += 1
                state.linkUp = false
                state.mux = nil
                state.info = nil
                state.battery = nil
            }
            failWaits(.connectionChanged)
        case .state(.ready, _):
            if session.keyRefused(canaryAnswered: false) {
                usable.resolve(.failure(ReGlassError.keyRefused))
                return
            }
            let generation = state.withLock { state -> Int in
                state.linkUp = true
                return state.generation
            }
            let state = state
            session.submit { [weak self] mux in
                let take = state.withLock { state -> Bool in
                    guard state.generation == generation, state.linkUp, state.mux == nil else { return false }
                    state.mux = mux
                    state.muxGeneration = generation
                    return true
                }
                guard take else { return }
                self?.evaluate()
                _ = try await DeviceRequests.onReady(mux)
            }
        case .state(.lost, _), .state(.disconnected, _):
            state.withLock { state in
                state.linkUp = false
                state.mux = nil
            }
            failWaits(.connectionChanged)
            if session.keyRefused(canaryAnswered: false) { usable.resolve(.failure(ReGlassError.keyRefused)) }
        case .state:
            break
        case .connectFailure(let error):
            state.withLock { $0.lastFailure = error }
        case .serviceMessage(let service, let type, let payload):
            if service == DataXService.peerBuildInfo, type == PeerBuildInfoMessageType.peerDeviceInfo,
               let info = try? PeerDeviceInfo.decode(payload) {
                if !info.serial.isEmpty, info.serial != serial {
                    usable.resolve(.failure(ReGlassError.serialMismatch))
                    return
                }
                state.withLock { $0.info = info }
            } else if service == DataXService.deviceInfo, type == DeviceInfoMessageType.deviceInfoResponse {
                state.current.inventory?.resolve(.success(payload))
            }
        case .serviceStatus(let service, let channel, let status):
            if service == DataXService.status, let wait = state.current.application {
                wait.result.resolve(.failure(WakeWordFault.refused(String(format: "svc28 status 0x%04x", status))))
            }
            if let transfer = state.current.transfer {
                await transfer.receiveStatus(service: service, channel: channel, status: status)
            }
            if let firmware = state.current.firmware {
                await firmware.receiveStatus(service: service, channel: channel, status: status)
            }
        case .warning:
            break
        }
        evaluate()
    }

    /// Resolves `usable` once everything holds on one attempt, or with the reason it never will.
    private func evaluate() {
        let snapshot = state.withLock { state -> (Ready?, PeerDeviceInfo?) in
            guard !state.stopped, state.linkUp, let mux = state.mux, state.muxGeneration == state.generation else {
                return (nil, nil)
            }
            return (Ready(mux: mux, generation: state.generation), state.info)
        }
        guard let ready = snapshot.0, let info = snapshot.1, info.serial == serial,
              session.trustResult != nil else { return }
        if !session.trustComplete {
            // A missing acceptance with svc100 answering is a refusal. Anything else (e.g. the glasses' own
            // credential arriving late) is still settling: keep waiting; the connect limit bounds it.
            if session.keyRefused(canaryAnswered: true) { usable.resolve(.failure(ReGlassError.keyRefused)) }
            return
        }
        // Wake-word links use the default Audio build check. Firmware confirmation can supply its own check.
        let accepts = firmwareAccepts ?? { WakeWordCatalog.isSupported(build: $0) }
        guard accepts(info.firmware) else {
            usable.resolve(.failure(WakeWordFault.unsupportedFirmware))
            return
        }
        if usable.resolve(.success(ready)) {
            let build = WakeWordCatalog.firmwareVersion(fromBuild: info.firmware) ?? "unknown"
            kitLog("wakeword", "link ready: trust both ways, serial matches, firmware \(build)")
        }
    }

    private func failWaits(_ fault: WakeWordFault) {
        let (inventory, application) = state.withLock { ($0.inventory, $0.application?.result) }
        inventory?.resolve(.failure(fault))
        application?.resolve(.failure(fault))
    }

    /// 8 s for the svc22 answer.
    private static let inventoryLimit: Duration = .seconds(8)
    /// 40 s for the app manager to start or stop the OTA application.
    static let applicationLimit: Duration = .seconds(40)
    /// 10 s for the stop after a failure.
    static let applicationCleanupLimit: Duration = .seconds(10)
}
