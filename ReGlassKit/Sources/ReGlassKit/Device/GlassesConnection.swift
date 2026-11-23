import Foundation

/// The glasses as the everyday connection sees them. Battery and case readings are last-known values: they stay
/// across reconnect attempts and are replaced only by fresh readings.
public struct GlassesStatus: Equatable, Sendable {
    public enum Connection: Equatable, Sendable {
        case connecting
        case connected
        /// Not connected; retrying. Carries why the last attempt failed, when known.
        case waiting(ReGlassError?)
        /// The glasses turned ReGlass's key down. The connection has stopped.
        case refused
    }

    public var connection: Connection = .waiting(nil)
    public var battery: Int?
    public var charging = false
    public var caseBattery: Int?
    public var caseCharging = false
    public var inCase: Bool?
    public var worn: Bool?
    public var firmware: String?
    public var model: String?
    public var serial: String?
}

/// The everyday link to verified glasses: connects with ReGlass's saved key, keeps reconnecting, and publishes
/// battery, case, wear and device info. It also carries the glasses' assistant service (`assistant`), registered on
/// every link once trust and the serial are confirmed, and the glasses' own timers (`timers`), which ride on it.
///
/// It never changes what is stored about the glasses except one thing: when the glasses refuse the key, it records
/// that and stops. Only a setup's verification marks glasses verified.
public final class GlassesConnection: Sendable {
    private let glasses: SavedGlasses
    private let session: GlassesLinkSession
    private let assistantService: AssistantService
    private let keeper = ConnectionKeeper()
    private let state = Locked(LiveState())
    private let input = GlassesInput()

    /// The glasses' assistant (wake, microphone, replies) on this connection. Its events last as long as the
    /// connection: availability goes false on every drop and true again once the next link is registered.
    public var assistant: any GlassesAssistantLink { assistantService }

    /// Timers that chime on the glasses by themselves (svc15 message 1100), kept in step across reconnects, and the
    /// glasses' alert when one rings. One per connection.
    public let timers: GlassesTimers

    private struct LiveState {
        var status = GlassesStatus()
        var lastFailure: ReGlassError?
        var statusChannel: Int?
        /// svc100 answered with the matching serial on the current attempt.
        var deviceInfoCurrent = false
        /// A pending wake word read: the next svc22 DeviceInfoResponse.
        var resourceRead: OneShot<[UInt8]>?
        /// A pending svc31 settings write: the next SettingsMessageType.setResponse.
        var settingsWrite: OneShot<Bool>?
        var resourceGeneration = 0
        var subscribers: [UUID: AsyncStream<GlassesStatus>.Continuation] = [:]
        var events: Task<Void, Never>?
        var started = false
        var stopped = false
    }

    /// Throws `.keyUnavailable` before the first unlock, `.noSavedIdentity` when ReGlass has no key or no record for
    /// these glasses, `.keyRefused` when they refused the key, `.verificationIncomplete` when setup never finished.
    public init(glasses: SavedGlasses) throws {
        guard let key = try IdentityStore.ownerKey(),
              let record = try IdentityStore.record(serial: glasses.serial) else { throw ReGlassError.noSavedIdentity }
        switch record.state {
        case .verified: break
        case .refused: throw ReGlassError.keyRefused
        case .pending, .unverified: throw ReGlassError.verificationIncomplete
        }
        self.glasses = SavedGlasses(id: record.glassesID, serial: record.serial, isVerified: true)
        let id = record.glassesID
        let assistant = AssistantService()
        assistantService = assistant
        timers = GlassesTimers(service: assistant)
        // svc15 is read inline by the link's reader, so envelope acks go out as soon as each envelope lands.
        // Route live translation on svc72 so ReGlass can reply on the peer channel the glasses open at link-up.
        let handlers: [Int: ServiceHandler] = [
            DataXService.assistant: { message, mux in await assistant.receive(message, from: mux) },
            DataXService.liveTranslation: { message, mux in await assistant.receiveLiveTranslation(message, from: mux) },
        ]
        session = GlassesLinkSession(transport: { L2CAPTransport(glasses: id) }, trust: ownerTrustHook(key),
                                     handlers: handlers)
        state.withLock { $0.status.serial = record.serial }
    }

    /// Status updates, starting with the current status. Ends when the connection stops.
    public func updates() -> AsyncStream<GlassesStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: GlassesStatus.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        let current: GlassesStatus? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.subscribers[id] = continuation
            return state.status
        }
        if let current {
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        } else {
            continuation.finish()
        }
        return stream
    }

    public func start() {
        let begin = state.withLock { state -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        guard begin else { return }
        kitLog("device", "connecting to glasses …\(glasses.serial.suffix(4))")
        keeper.hold(glasses.id)
        update { $0.connection = .connecting }
        let session = session
        let task = Task { [weak self] in
            await session.start()
            for await event in session.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        state.withLock { $0.events = task }
    }

    /// Touches on the glasses that reach the phone: svc28 pushes 2011 (touchpad) and 2035 (action button), decoded
    /// passively. A repeat of the same kind within 250 ms is dropped. In other modes the glasses handle play
    /// and pause locally. Each call creates a stream that lasts across reconnects until the connection stops.
    public func inputs() -> AsyncStream<GlassesInputEvent> {
        input.stream()
    }

    /// Asks the glasses for a fresh status snapshot. Does nothing while disconnected.
    public func refresh() {
        guard let channel = state.withLock({ $0.status.connection == .connected ? $0.statusChannel : nil }) else { return }
        session.submit { mux in try await DeviceRequests.subscribe(mux, on: channel) }
    }

    /// Reads stored wake word metadata, not the running DSP model. Read-only: one empty svc22 device-info
    /// request (this firmware does not read its body), as the live connection already sends at every READY.
    /// Throws `.wakeWordUnavailable` on other firmware (nothing is sent), `.linkLost` while not connected or when
    /// the link drops, `.timedOut` after 8 s.
    public func readWakeWord() async throws -> InstalledWakeWord {
        // READY comes before svc100's answer; give it a moment rather than fail a read made right at connect.
        let answered = ContinuousClock.now + .seconds(5)
        var ready = deviceInfoReady()
        let generation = ready.generation
        while ready.generation == generation, ready.connected, !ready.answered, ContinuousClock.now < answered {
            try await Task.sleep(for: .milliseconds(100))
            ready = deviceInfoReady()
        }
        guard ready.generation == generation, ready.connected, ready.answered else { throw ReGlassError.linkLost }
        guard session.trustComplete else { throw ReGlassError.verificationIncomplete }
        guard WakeWordCatalog.isSupported(build: ready.firmware) else { throw ReGlassError.wakeWordUnavailable }
        let waiter = OneShot<[UInt8]>()
        let previous = try state.withLock { state -> OneShot<[UInt8]>? in
            guard state.resourceGeneration == generation, !state.stopped else { throw ReGlassError.linkLost }
            defer { state.resourceRead = waiter }
            return state.resourceRead
        }
        previous?.resolve(.failure(ReGlassError.cancelled))
        defer { state.withLock { if $0.resourceRead === waiter { $0.resourceRead = nil } } }
        session.submit { [self] mux in
            do {
                guard state.withLock({ $0.resourceGeneration == generation && !$0.stopped }) else {
                    throw ReGlassError.linkLost
                }
                try await mux.sendOnService(DataXService.deviceInfo, DeviceInfoMessageType.deviceInfoRequest, [])
            } catch {
                // A failed send means the link is going; the attempt ends on its own.
                waiter.resolve(.failure(ReGlassError.linkLost))
            }
        }
        let payload = try await withTimeout(.seconds(8), "the wake word read") { try await waiter.value() }
        guard state.withLock({ $0.resourceGeneration == generation && !$0.stopped }) else { throw ReGlassError.linkLost }
        let inventory: ResourceInventory
        do { inventory = try ResourceInventory.decode(payload) } catch {
            throw ReGlassError.protocolFailure("the resource list could not be read")
        }
        let installed = WakeWordCatalog.classify(inventory)
        kitLog("device", "wake word resource readback: \(installed); running model not reported")
        // What the glasses list, so an unrecognised state can be understood: ids, versions, types and feature
        // status only (resource metadata, nothing personal).
        let artifacts = inventory.artifacts.map { "\($0.id ?? "?")@\($0.version ?? "?")\($0.type.map { " [\($0)]" } ?? "")" }
        let features = inventory.features.map { "\($0.name ?? "?")=\($0.status.map(String.init) ?? "?")" }
        kitLog("device", "wake word resources listed: artifacts [\(artifacts.joined(separator: ", "))], "
               + "features [\(features.joined(separator: ", "))]")
        if let known = WakeWordCatalog.known(inventory) {
            kitLog("device", "wake word resource version: \(known.version), \(known.enabled ? "enabled" : "not enabled")")
        }
        return installed
    }

    /// Sends settings over svc31 message 2, including Adaptive Volume (tag 80) and Spatial Audio (tag 286).
    /// The glasses confirm with message 3, tag 1 set to 2.
    @discardableResult
    public func setAudioSettings(_ settings: GlassesAudioSettings) async throws -> Bool {
        let payload = try settings.encode()
        guard !payload.isEmpty else { return true }
        let answered = ContinuousClock.now + .seconds(5)
        var ready = deviceInfoReady()
        let generation = ready.generation
        while ready.generation == generation, ready.connected, !ready.answered, ContinuousClock.now < answered {
            try await Task.sleep(for: .milliseconds(100))
            ready = deviceInfoReady()
        }
        guard ready.generation == generation, ready.connected, ready.answered else { throw ReGlassError.linkLost }
        guard session.trustComplete else { throw ReGlassError.verificationIncomplete }
        let waiter = OneShot<Bool>()
        let previous = try state.withLock { state -> OneShot<Bool>? in
            guard state.resourceGeneration == generation, !state.stopped else { throw ReGlassError.linkLost }
            defer { state.settingsWrite = waiter }
            return state.settingsWrite
        }
        previous?.resolve(.failure(ReGlassError.cancelled))
        defer { state.withLock { if $0.settingsWrite === waiter { $0.settingsWrite = nil } } }
        session.submit { [self] mux in
            do {
                guard state.withLock({ $0.resourceGeneration == generation && !$0.stopped }) else {
                    throw ReGlassError.linkLost
                }
                let channel = await mux.openChannel(DataXService.settings)
                try await mux.send(channel, payload, messageType: SettingsMessageType.set, serviceId: DataXService.settings)
            } catch {
                waiter.resolve(.failure(ReGlassError.linkLost))
            }
        }
        let ok = try await withTimeout(.seconds(5), "the audio settings update") { try await waiter.value() }
        var parts: [String] = []
        if let avc = settings.adaptiveVolume { parts.append("avc=\(avc ? "on" : "off")") }
        if let spatial = settings.spatialAudio { parts.append("spatial=\(spatial ? "on" : "off")") }
        if let assistant = settings.assistantEnabled { parts.append("assistant=\(assistant ? "on" : "off")") }
        if let wake = settings.wakeWordEnabled { parts.append("wakeword=\(wake ? "on" : "off")") }
        kitLog("device", "svc31 settings (\(parts.joined(separator: ", "))): \(ok ? "confirmed" : "not confirmed")")
        return ok
    }

    /// Stops reconnecting and returns once the link has let go of the glasses.
    public func stop() async {
        let (events, subscribers) = state.withLock { state -> (Task<Void, Never>?, [AsyncStream<GlassesStatus>.Continuation]) in
            state.stopped = true
            defer { state.subscribers = [:] }
            return (state.events, Array(state.subscribers.values))
        }
        endResourceRead()
        input.finish()
        timers.shutdown()
        await assistantService.shutdown()
        await session.stop()
        await events?.value
        keeper.release()
        for subscriber in subscribers { subscriber.finish() }
    }

    // MARK: Events

    private func handle(_ event: LinkEvent) async {
        // After a stop (the app's, or a refusal) the session still drains its last events; they change nothing.
        guard !state.withLock({ $0.stopped }) else { return }
        switch event {
        case .state(let link, _):
            switch link {
            case .connecting, .linkSetup, .trust:
                endResourceRead()
                await assistantService.linkDown()
                update { $0.connection = .connecting }
            case .ready:
                // Glasses that refuse the key can still finish link setup; their own credential arriving while
                // ours was not accepted is the refusal.
                if session.keyRefused(canaryAnswered: false) {
                    await refuse()
                    return
                }
                state.withLock { $0.lastFailure = nil }
                update { $0.connection = .connected }
                session.submit { [weak self] mux in
                    let channel = try await DeviceRequests.onReady(mux)
                    self?.state.withLock { $0.statusChannel = channel }
                }
            case .lost, .disconnected:
                // Refusing glasses also withhold EndLinkSetup, so the attempt ends without READY.
                if session.keyRefused(canaryAnswered: false) {
                    await refuse()
                    return
                }
                state.withLock { $0.statusChannel = nil }
                endResourceRead()
                await assistantService.linkDown()
                let failure = state.withLock { $0.lastFailure }
                update { if $0.connection != .refused { $0.connection = .waiting(failure) } }
            }

        case .connectFailure(let error):
            state.withLock { $0.lastFailure = error }
            update { if case .waiting = $0.connection { $0.connection = .waiting(error) } }

        case .serviceMessage(let service, let type, let payload):
            if service == DataXService.peerBuildInfo, type == PeerBuildInfoMessageType.peerDeviceInfo,
               let info = try? PeerDeviceInfo.decode(payload) {
                if !info.serial.isEmpty, info.serial != glasses.serial {
                    kitLog("device", "different glasses answered; stopping")
                    await stopAfterProblem(.waiting(.serialMismatch))
                    return
                }
                // The glasses answered, so the link works; if they didn't accept our key, they don't know it.
                if session.keyRefused(canaryAnswered: true) {
                    await refuse()
                    return
                }
                let firstAnswer = state.withLock { state -> Bool in
                    defer { state.deviceInfoCurrent = true }
                    return !state.deviceInfoCurrent
                }
                update {
                    if !info.firmware.isEmpty { $0.firmware = info.firmware }
                    if !info.model.isEmpty { $0.model = info.model }
                    if !info.serial.isEmpty { $0.serial = info.serial }
                }
                if firstAnswer, info.serial == glasses.serial {
                    await startAssistant(replyBitrate: info.preferredReplyBitrate)
                }
            } else if service == DataXService.deviceInfo, type == DeviceInfoMessageType.deviceInfoResponse {
                // The answer to a wake word read (or to the clock sync; this firmware answers both the same way).
                state.withLock { $0.resourceRead }?.resolve(.success(payload))
            } else if service == DataXService.settings, type == SettingsMessageType.setResponse {
                state.withLock { $0.settingsWrite }?.resolve(.success(GlassesAudioSettings.decodeSuccess(payload)))
            } else if service == DataXService.status, DeviceStateReading.isDeviceState(type),
                      let reading = try? DeviceStateReading.decode(payload) {
                input.receive(messageType: type, payload: payload)   // touch pushes (2011, 2035); passive
                update { status in
                    if let battery = reading.batteryPercent { status.battery = battery }
                    if let charging = reading.charging { status.charging = charging }
                    if let inCase = reading.inCase { status.inCase = inCase }
                    if let caseBattery = reading.caseBatteryPercent { status.caseBattery = caseBattery }
                    if let caseCharging = reading.caseCharging { status.caseCharging = caseCharging }
                    if let worn = reading.worn { status.worn = worn }
                }
            } else if !Self.servicesInUse.contains(service) {
                // Passive: anything the glasses send on a service ReGlass doesn't use is logged by kind.
                await assistantService.observe(service: service, type: type, size: payload.count)
            }

        case .serviceStatus(let service, let channel, let status):
            if service == DataXService.assistant {
                await assistantService.serviceStatus(channel: channel, status: status)
            } else if service == NotificationMessages.service {
                await assistantService.notificationStatus(status)
            }

        case .warning:
            break   // the session already logged it
        }
    }

    /// Registers the assistant once the link is READY, trusted both ways, and svc100 named the saved glasses.
    /// The registration runs beside the command loop, never in it.
    private func startAssistant(replyBitrate: Int?) async {
        guard session.trustComplete else {
            kitLog("assistant", "trust is incomplete on this link; the assistant stays off")
            return
        }
        let token = await assistantService.linkToken()
        let assistant = assistantService
        session.submit { mux in await assistant.linkReady(mux, token: token, replyBitrate: replyBitrate) }
    }

    private func deviceInfoReady() -> (connected: Bool, answered: Bool, firmware: String?, generation: Int) {
        state.withLock { state in
            (state.status.connection == .connected && !state.stopped, state.deviceInfoCurrent, state.status.firmware, state.resourceGeneration)
        }
    }

    /// A new attempt or a dropped link: a pending wake word read can't be answered on it.
    private func endResourceRead() {
        let (read, write) = state.withLock { state -> (OneShot<[UInt8]>?, OneShot<Bool>?) in
            state.deviceInfoCurrent = false
            state.resourceGeneration += 1
            defer { state.settingsWrite = nil }
            return (state.resourceRead, state.settingsWrite)
        }
        read?.resolve(.failure(ReGlassError.linkLost))
        write?.resolve(.failure(ReGlassError.linkLost))
    }

    /// The glasses turned the key down: record it (the one store write this class makes) and stop.
    private func refuse() async {
        kitLog("device", "the glasses refused ReGlass's key; stopping")
        do {
            try IdentityStore.setState(.refused, serial: glasses.serial)
        } catch {
            kitLog("device", "could not record the refusal: \(error)")
        }
        await stopAfterProblem(.refused)
    }

    private func stopAfterProblem(_ connection: GlassesStatus.Connection) async {
        update { $0.connection = connection }
        let subscribers = state.withLock { state -> [AsyncStream<GlassesStatus>.Continuation] in
            state.stopped = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        input.finish()
        timers.shutdown()
        await assistantService.shutdown()
        // This runs on the event task; stopping the session ends the event stream, then this task returns.
        await session.stop()
        keeper.release()
        for subscriber in subscribers { subscriber.finish() }
    }

    /// Services the live connection reads itself; a message from any other is only logged.
    static let servicesInUse: Set<Int> = [
        DataXService.linkSetup, DataXService.assistant, DataXService.deviceInfo, DataXService.status,
        DataXService.settings, DataXService.identity, DataXService.liveTranslation, DataXService.peerBuildInfo,
    ]

    private func update(_ change: (inout GlassesStatus) -> Void) {
        let (status, subscribers) = state.withLock { state -> (GlassesStatus?, [AsyncStream<GlassesStatus>.Continuation]) in
            var next = state.status
            change(&next)
            guard next != state.status else { return (nil, []) }
            state.status = next
            return (next, Array(state.subscribers.values))
        }
        guard let status else { return }
        for subscriber in subscribers { subscriber.yield(status) }
    }
}
