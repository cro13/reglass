import Foundation

/// Finds the person's glasses and lets iOS pair them.
public final class GlassesFinder: Sendable {
    /// The first scan may be waiting on the permission prompt.
    static let scanPowerTimeout: Duration = .seconds(30)
    static let pairPowerTimeout: Duration = .seconds(10)
    /// How often the held glasses are listed again and silent adverts dropped.
    static let sweepInterval: Duration = .seconds(2)
    /// Long enough for the person to answer iOS's pairing prompt and for each read behind it.
    static let pairingTimeout: Duration = .seconds(90)
    /// The connection itself needs no prompt, so it shouldn't wait the full pairing time: a reachable pair connects
    /// in well under a second. A shorter bound turns a stuck connect into a quick retry instead of a long spin.
    static let connectTimeout: Duration = .seconds(20)
    /// A connect right after the glasses reset, or right after a probe link closed, can time out once before it
    /// takes. Retry a no-answer a couple of times; a stale bond or a declined prompt is not retried.
    static let pairingAttempts = 3
    static let pairingRetryDelay: Duration = .seconds(2)
    /// How long a successful pairing keeps its LE connection, so the ownership step that follows joins it instead of
    /// connecting again. Closing it the moment the bond is made and reconnecting 0.7 s later left freshly reset
    /// glasses unreachable until they were restarted. The next step holds the connection well within this time.
    static let handoverGrace: Duration = .seconds(15)

    private let central: BluetoothCentral

    public init() {
        central = .shared
    }

    /// Held peripherals first, then adverts; yields the full current list on every change. Finishes by throwing
    /// ReGlassError.bluetoothOff / .bluetoothDenied / .bluetoothUnsupported. Stops scanning when the consumer stops.
    public func scan() -> AsyncThrowingStream<[NearbyGlasses], Error> {
        let central = central
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let search = Task {
                do {
                    try await central.waitUntilPoweredOn(timeout: Self.scanPowerTimeout)
                    let list = NearbyPublisher(continuation)
                    let held = await central.glassesConnectedToPhone()
                    list.update { $0.update(held: held) }
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await advertisement in central.advertisements() {
                                guard let glasses = advertisement.glasses else { continue }
                                list.update { $0.hear(glasses) }
                            }
                        }
                        group.addTask {
                            while true {
                                try await Task.sleep(for: Self.sweepInterval)
                                let held = await central.glassesConnectedToPhone()
                                list.update { $0.update(held: held) }
                            }
                        }
                        defer { group.cancelAll() }
                        try await group.next()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ReGlassError.from(error))
                }
            }
            continuation.onTermination = { _ in search.cancel() }
        }
    }

    /// Lets iOS pair glasses not yet paired with this iPhone (iOS shows its own prompt). ReGlassError on failure.
    ///
    /// Connects and reads the readable characteristics in Meta's service. iOS starts pairing when a read
    /// requires encryption.
    public func pair(_ id: UUID) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await pairing(id)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mapped = ReGlassError.from(error)
                // A transient no-answer (the connect didn't take in time) is worth another try; a stale bond or a
                // declined prompt needs the person to act, so it surfaces at once.
                guard mapped == .noAnswer, attempt < Self.pairingAttempts, !Task.isCancelled else { throw mapped }
                kitLog("bluetooth", "pairing \(BluetoothCentral.label(id)) didn't answer; retry \(attempt + 1) of \(Self.pairingAttempts)")
                try await Task.sleep(for: Self.pairingRetryDelay)
            }
        }
    }

    private func pairing(_ id: UUID) async throws {
        try await central.waitUntilPoweredOn(timeout: Self.pairPowerTimeout)
        let label = BluetoothCentral.label(id)
        let holder = ConnectionHolder(role: "pairing", reconnects: false)
        kitLog("bluetooth", "pairing \(label)")
        do {
            try await central.connect(id, holder: holder, timeout: Self.connectTimeout)
        } catch ReGlassError.glassesUnknown {
            // Heard by the scan but not handed back by iOS: they went quiet.
            throw ReGlassError.noAnswer
        }
        var paired = false
        defer {
            if paired {
                // Hand the connection over rather than drop it: the ownership step's own hold joins it, and this one
                // lets go a little later. Should setup stop instead, the connection closes once the grace is over.
                let central = central
                Task {
                    try? await Task.sleep(for: Self.handoverGrace)
                    central.release(id, holder: holder)
                }
            } else {
                central.release(id, holder: holder)
            }
        }
        var answered = 0
        var readable: [CharacteristicSummary] = []
        do {
            guard let characteristics = try await central.characteristics(in: MetaGatt.service, on: id) else {
                kitLog("bluetooth", "\(label) has no Meta service; nothing to pair over")
                return
            }
            readable = characteristics.filter(\.isReadable)
            kitLog("bluetooth", "found \(characteristics.count) characteristics in Meta's service (\(readable.count) readable)")
            for characteristic in readable {
                do {
                    _ = try await central.readValue(of: characteristic.uuid, in: MetaGatt.service, on: id,
                                                    timeout: Self.pairingTimeout)
                    answered += 1
                } catch let error where isStaleBondFailure(error) {
                    // iOS still holds the old bond; the glasses refuse the encrypted read. Forgetting them in
                    // Settings → Bluetooth is the only cure, so don't let this read as a retryable no-answer.
                    kitLog("bluetooth", "pairing \(label) needs a fresh bond (forget in Settings): \(logDescription(error))")
                    throw ReGlassError.bondStale
                } catch let error where isPairingFailure(error) {
                    kitLog("bluetooth", "pairing \(label) declined: \(logDescription(error))")
                    throw ReGlassError.pairingDeclined
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    kitLog("bluetooth", "pairing read failed (\(logDescription(error))); trying the next one")
                }
            }
        } catch ReGlassError.pairingDeclined {
            throw ReGlassError.pairingDeclined
        } catch ReGlassError.bondStale {
            throw ReGlassError.bondStale
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            kitLog("bluetooth", "pairing \(label) stopped: \(logDescription(error))")
            throw ReGlassError.noAnswer
        }
        paired = true
        kitLog("bluetooth", "paired \(label) (\(answered) of \(readable.count) reads answered); keeping the connection "
               + "for the next step")
    }
}

/// One scan's list, yielded whenever it changes. Updates come from the advert loop and the sweep; the lock keeps
/// them, and the order of what is yielded, in step.
private final class NearbyPublisher: Sendable {
    private struct State {
        var list = NearbyList()
        var lastYielded: [NearbyGlasses]?
    }

    private let state = Locked(State())
    private let continuation: AsyncThrowingStream<[NearbyGlasses], Error>.Continuation

    init(_ continuation: AsyncThrowingStream<[NearbyGlasses], Error>.Continuation) {
        self.continuation = continuation
    }

    func update(_ change: (inout NearbyList) -> Void) {
        state.withLock { state in
            change(&state.list)
            let now = state.list.glasses()
            guard now != state.lastYielded else { return }
            state.lastYielded = now
            continuation.yield(now)
        }
    }
}
