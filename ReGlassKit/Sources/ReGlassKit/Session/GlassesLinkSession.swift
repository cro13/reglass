import Foundation

/// Work to run on the live multiplexer from the session's own task. It may send, but must not call
/// `mux.receive()`: the session's pump is the one reader while READY.
typealias SessionWork = @Sendable (DataXMultiplexer) async throws -> Void

/// Owns the link to one pair of glasses: it connects, runs the AirShield handshake, the optional svc36 trust
/// exchange and EndLinkSetup, reaches READY, pumps service traffic, and reconnects with backoff until `stop`.
///
/// An actor: one task drives the connection loop, callers `submit` work and read `events` concurrently.
actor GlassesLinkSession {
    private let transportFactory: @Sendable () throws -> FrameTransport
    private let trust: TrustHook?
    private let handlers: [Int: ServiceHandler]

    /// Everything that happens on the link. One consumer; delivered in order, dropping nothing.
    nonisolated let events: AsyncStream<LinkEvent>
    private nonisolated let eventSink: AsyncStream<LinkEvent>.Continuation

    // Work queued by `submit`, consumed by the command loop at READY. Persists across attempts.
    private nonisolated let commandQueue = AsyncQueue<SessionWork>()
    // Woken when `stop` is called, to cut a reconnect backoff short.
    private nonisolated let stopSignal = OneShot<Void>()
    // The live transport, readable by the deadline watchdog and by `stop` without hopping onto the actor.
    private nonisolated let activeTransportBox = Locked<FrameTransport?>(nil)
    // The latest trust verdict and whether the peer's own credential arrived, readable synchronously.
    private nonisolated let latestTrust = Locked<TrustResult?>(nil)

    private var stopped = false
    private var supervisor: Task<Void, Never>?

    init(
        transport: @escaping @Sendable () throws -> FrameTransport,
        trust: TrustHook? = nil,
        handlers: [Int: ServiceHandler] = [:]
    ) {
        self.transportFactory = transport
        self.trust = trust
        self.handlers = handlers
        let made = AsyncStream.makeStream(of: LinkEvent.self)
        events = made.stream
        eventSink = made.continuation
    }

    /// The latest svc36 trust verdict, or nil before any exchange on the current attempt.
    nonisolated var trustResult: TrustResult? { latestTrust.current }
    /// Trust completed in both directions on the current attempt.
    nonisolated var trustComplete: Bool { latestTrust.current?.complete == true }
    /// The glasses sent their own credential during the trust exchange (and it was acknowledged).
    nonisolated var credentialReceived: Bool { latestTrust.current?.rxOk == true }

    /// Start connecting. Returns at once; the work happens on the session's own task.
    func start() {
        guard supervisor == nil, !stopped else { return }
        supervisor = Task { await self.supervise() }
    }

    /// Ask the session to finish, and wait until it has let go of the socket.
    func stop() async {
        stopped = true
        stopSignal.resolve(.success(()))
        activeTransportBox.current?.close()
        await supervisor?.value
        supervisor = nil
        eventSink.finish()
    }

    /// Queue work for the session's task; it runs when an attempt has a live multiplexer. Dropped work that
    /// is never reached simply waits in the queue.
    nonisolated func submit(_ work: @escaping SessionWork) {
        commandQueue.push(work)
    }

    /// Force the live transport closed without stopping the session. Resumes any sender blocked in a write with
    /// `.linkLost` (the transport's own close), so a stuck write that cancellation can't reach is unblocked. The
    /// supervisor then reconnects unless `stop` was also called. Safe when nothing is connected.
    nonisolated func closeTransport() {
        activeTransportBox.current?.close()
    }

    // MARK: Connection loop

    private func supervise() async {
        var attempt = 0
        while true {
            let reachedReady: Bool
            do { reachedReady = try await runOnce() } catch { return }   // cancelled
            if reachedReady { attempt = 0 }   // a link that reached READY restarts the backoff
            if stopped { return }
            await waitBackoff(Self.backoff[min(attempt, Self.backoff.count - 1)])
            if stopped { return }
            attempt += 1
        }
    }

    private func waitBackoff(_ duration: Duration) async {
        let signal = stopSignal
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: duration) }
            group.addTask { _ = try? await signal.value() }
            _ = await group.next()
            group.cancelAll()
        }
    }

    /// One connection attempt. Throws only `CancellationError`, to end `supervise`.
    private func runOnce() async throws -> Bool {
        if stopped { return false }   // stop() may have run before this attempt began
        var reachedReady = false
        var connecting = true
        var secureChannel: SecureChannel?
        resetTrust()
        publish(.state(.connecting, reason: ""))

        let transport: FrameTransport
        do {
            transport = try transportFactory()
        } catch {
            let reason = reason(error, lastCommand: nil)
            publish(.warning(reason))
            if let kitError = error as? ReGlassError, Self.isConnectFailure(kitError) { publish(.connectFailure(kitError)) }
            publish(.state(.lost, reason: reason))
            return false
        }
        activeTransportBox.withLock { $0 = transport }
        defer {
            activeTransportBox.withLock { $0 = nil }
            transport.close()
        }

        do {
            try await transport.connect()
            connecting = false
            publish(.state(.linkSetup, reason: ""))

            let channel = SecureChannel(transport)
            secureChannel = channel
            try await withLinkDeadline(Self.linkSetupReadTimeout, transport,
                                       "the glasses stopped answering during link setup") {
                try await channel.open()
            }

            let registry = ChannelRegistry()
            registry.bindInbound(DataXChannel.linkSetup, DataXService.linkSetup)
            let peerChannel = await channel.peerLinkSetupChannel
            // The peer's encrypted link setup can continue on its negotiated request channel.
            if peerChannel & 0x8000 != 0 { registry.bindInbound(peerChannel, DataXService.linkSetup) }
            let mux = DataXMultiplexer(channel, registry)

            let reader = try await mux.startReader()
            do {
                if let trust {
                    publish(.state(.trust, reason: ""))
                    guard let binding = await channel.binding else {
                        throw ReGlassError.protocolFailure("no handshake binding")
                    }
                    let result = try await trust(mux, binding)   // the hook bounds its own wait
                    latestTrust.withLock { $0 = result }
                    if !result.complete { publish(.warning(trustFault(result))) }
                }

                try await channel.finishLinkSetup()
                try await withLinkDeadline(Self.endLinkSetupTimeout, transport,
                                           "the glasses did not send their EndLinkSetup") {
                    try await self.answerTheirEndLinkSetup(mux, peerChannel: peerChannel, registry: registry)
                }
                try await settleChannels(mux, registry)

                publish(.state(.ready, reason: ""))
                reachedReady = true
                try await pump(mux, registry)
                publish(.state(.disconnected, reason: ""))
            } catch {
                reader.cancel(); await reader.value
                throw error
            }
            reader.cancel(); await reader.value
        } catch {
            if error is CancellationError { throw error }
            if stopped {
                // stop() closed the socket underneath the reader; this end finishing is not the link failing.
                publish(.state(.disconnected, reason: ""))
            } else {
                let reason = reason(error, lastCommand: secureChannel?.lastStreamCommand)
                publish(.warning(reason))
                if connecting, let kitError = error as? ReGlassError, Self.isConnectFailure(kitError) {
                    publish(.connectFailure(kitError))
                }
                publish(.state(.lost, reason: reason))
            }
        }
        return reachedReady
    }

    /// Wait for the glasses' own EndLinkSetup, then acknowledge it on the mirror. Everything else that lands
    /// meanwhile is handled as a normal message.
    private func answerTheirEndLinkSetup(_ mux: DataXMultiplexer, peerChannel: Int, registry: ChannelRegistry) async throws {
        while true {
            let message = try await mux.receive()
            let info = message.info
            let expectedChannel = info.channelId == peerChannel || info.channelId == DataXChannel.linkSetup
            let registered = registry.serviceForInbound(info.channelId)
            // A closed-type frame may already have dropped its registry entry; the handshake still identifies
            // these exact channels as link setup, and an explicit other service wins.
            let service = info.serviceId != 0 ? info.serviceId
                : (registered != 0 ? registered : (expectedChannel ? DataXService.linkSetup : 0))
            if expectedChannel, info.channelId & 0x8000 != 0, service == DataXService.linkSetup,
               info.flags.valid, info.flags.complete, !info.flags.hasError,
               info.messageType == LinkSetupMessageType.endLinkSetup {
                try await mux.sendStatus(DataXMultiplexer.mirror(info.channelId), DataXStatus.success)
                return
            }
            try await handleMessage(message, mux, registry)
        }
    }

    /// Drain what the glasses said during link setup before anyone allocates a local channel.
    private func settleChannels(_ mux: DataXMultiplexer, _ registry: ChannelRegistry) async throws {
        while !stopped {
            guard let message = await mux.poll() else { break }
            try await handleMessage(message, mux, registry)
        }
    }

    /// Read the link until the attempt ends, with submitted work running beside the reads. The first loop to
    /// finish (a read failing, a command throwing) ends the pump and cancels the other.
    private func pump(_ mux: DataXMultiplexer, _ registry: ChannelRegistry) async throws {
        let queue = commandQueue
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true { try await (queue.next())(mux) }
            }
            group.addTask { [self] in
                while true { try await handleMessage(try await mux.receive(), mux, registry) }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func handleMessage(_ message: DataXMessage, _ mux: DataXMultiplexer, _ registry: ChannelRegistry) async throws {
        let info = message.info
        // A peer-opened channel names its service on its first message only; record it or every later frame
        // on that channel is attributed to service 0.
        if info.serviceId != 0, !info.flags.isClosed { registry.bindInbound(info.channelId, info.serviceId) }
        let serviceId = info.serviceId != 0 ? info.serviceId : registry.serviceForInbound(info.channelId)

        // The glasses open their device-peer trust and constellation auth toward every companion; refuse them.
        if Self.refusedPeerServices.contains(serviceId), info.channelId & 0x8000 != 0, !info.flags.hasError {
            try await mux.sendStatus(DataXMultiplexer.mirror(info.channelId), DataXStatus.serviceNotFound)
        }

        if let handler = handlers[serviceId], !info.flags.hasError {
            do { try await handler(message, mux) }
            catch is CancellationError { throw CancellationError() }
            catch { publish(.warning("responder for service \(serviceId) failed")) }
        }

        if info.flags.hasError {
            if info.errorId != DataXStatus.success {
                publish(.warning(String(format: "service %ld answered status 0x%04lx on channel 0x%04lx",
                                        serviceId, info.errorId, info.channelId)))
                publish(.serviceStatus(service: serviceId, channel: info.channelId, status: info.errorId))
            }
            return
        }
        // An empty close frame only ends a channel, and the registry has already forgotten whose it was.
        if info.flags.isClosed && message.payload.isEmpty { return }
        publish(.serviceMessage(service: serviceId, type: info.messageType, payload: message.payload))
    }

    // MARK: Deadlines and helpers

    /// Run `body` with a bound on how long it may wait for the peer. A watchdog closes the transport once the
    /// deadline passes, which wakes the blocked read; the first of the two to settle wins, so a body that is up
    /// is never torn down. `body` runs inline (it may touch this actor's state).
    private func withLinkDeadline<T>(_ timeout: Duration, _ transport: FrameTransport, _ what: String,
                                     _ body: () async throws -> T) async throws -> T {
        let settled = Locked(false)
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            if claim(settled) { transport.close() }
        }
        defer { watchdog.cancel() }
        do {
            let result = try await body()
            _ = claim(settled)   // so a watchdog that has not fired cannot close a link that is up
            return result
        } catch {
            if error is CancellationError { throw error }
            // A failed claim means the watchdog got there first, so this failure IS the deadline.
            if !claim(settled) { throw ReGlassError.timedOut(what) }
            throw error
        }
    }

    /// Claim a one-shot flag; true only for the caller that set it.
    private func claim(_ flag: Locked<Bool>) -> Bool {
        flag.withLock { if $0 { return false }; $0 = true; return true }
    }

    private func publish(_ event: LinkEvent) {
        switch event {
        case .state(let state, let reason):
            kitLog("link", reason.isEmpty ? "\(state)" : "\(state): \(reason)")
        case .connectFailure(let error):
            kitLog("link", "connect failed: \(error)")
        case .warning(let text):
            kitLog("link", text)
        case .serviceMessage, .serviceStatus:
            break   // never log payload bytes; a status was already logged as its warning
        }
        eventSink.yield(event)
    }

    private func resetTrust() {
        latestTrust.withLock { $0 = nil }
    }

    private func reason(_ error: Error, lastCommand: Int?) -> String {
        let base = error is CancellationError ? "cancelled" : String(describing: error)
        return lastCommand == streamCommandLost ? base + " (the glasses signalled stream 0 LOST)" : base
    }

    private func trustFault(_ result: TrustResult) -> String {
        var faults: [String] = []
        if !result.txOk { faults.append("the glasses did not accept our credential") }
        if !result.rxOk { faults.append("the glasses sent no credential of their own") }
        return "trust incomplete: " + faults.joined(separator: " and ")
    }

    private static func isConnectFailure(_ error: ReGlassError) -> Bool {
        switch error {
        case .bluetoothUnsupported, .bluetoothOff, .bluetoothDenied, .glassesUnknown, .noAnswer, .pairingDeclined:
            return true
        default:
            return false
        }
    }

    /// 5.0 s: the working client waits exactly that long for the peer's EndLinkSetup.
    private static let endLinkSetupTimeout: Duration = .seconds(5)
    /// 10.0 s: the reference bounds every link-setup read with this.
    private static let linkSetupReadTimeout: Duration = .seconds(10)
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    /// svc30 (device-peer trust) and svc79 (constellation auth): refused toward this companion.
    private static let refusedPeerServices: Set<Int> = [30, 79]
}
