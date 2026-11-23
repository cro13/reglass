import CoreBluetooth
import Foundation

/// The byte pipe under the encrypted link: an LE L2CAP channel to one pair of glasses, on the PSM their GATT service
/// names. iOS needs the app's own LE connection before it opens a channel, so `connect` makes one (joining the
/// keeper's when it is up) and holds it until `close`. A fresh transport per connection attempt.
final class L2CAPTransport: FrameTransport {
    static let powerTimeout: Duration = .seconds(10)
    static let connectTimeout: Duration = .seconds(12)
    /// The whole PSM read, all its GATT steps included. On failure the default PSM is tried.
    static let psmReadTimeout: Duration = .seconds(6)
    static let channelTimeout: Duration = .seconds(10)
    /// Closing a channel's streams finishes asynchronously; the next channel to the same glasses waits this long.
    static let reopenGap: Duration = .milliseconds(400)
    /// Between retries while iOS still holds the previous channel on the PSM (CBInternalErrorDomain 24).
    static let stillClosingRetryDelay: Duration = .milliseconds(750)
    /// How long to keep retrying the open while iOS releases the previous channel. iOS can take several seconds to
    /// free an L2CAP channel after a close, and only then will it open a new one on the same PSM. Retrying across
    /// that window opens the moment it frees, instead of giving up and waiting out the session's 2 s/4 s backoff.
    static let stillClosingLimit: Duration = .seconds(15)

    private let glasses: UUID
    private let central: BluetoothCentral
    private let holder = ConnectionHolder(role: "link", reconnects: false)
    private let state = Locked(State())
    private let closed = OneShot<Void>()

    private struct State {
        var isClosed = false
        var holdsConnection = false
        var pipe: L2CAPPipe?
        var watch: UUID?
    }

    /// What earlier channels to each pair taught: their PSM (read once per pair), and when the last
    /// channel closed.
    private struct ChannelHistory {
        var psm: UInt16?
        var closedAt: ContinuousClock.Instant?
    }

    private static let history = Locked<[UUID: ChannelHistory]>([:])

    init(glasses: UUID, central: BluetoothCentral = .shared) {
        self.glasses = glasses
        self.central = central
    }

    /// Opens the link: Bluetooth on, LE connection, PSM, L2CAP channel. Throws `.bluetoothOff` / `.bluetoothDenied` /
    /// `.bluetoothUnsupported`, `.glassesUnknown`, `.pairingDeclined`, `.noAnswer`, or `.linkLost` when the LE link
    /// drops on the way or `close()` is called meanwhile. Cancellation-aware; on failure the transport is closed.
    func connect() async throws {
        do {
            // `close()` from anywhere ends the attempt as cancelling it would.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.open() }
                group.addTask {
                    try await self.closed.value()
                    throw ReGlassError.linkLost
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            // Only here, after both children ended, so the attempt's own error is the one reported.
            close()
            throw error
        }
    }

    func send(_ frame: [UInt8]) async throws {
        guard let pipe = state.withLock({ $0.pipe }) else { throw ReGlassError.linkLost }
        try await pipe.send(frame)
    }

    /// One whole frame. Throws `.linkLost` once the link is closed or drops, or `.bluetoothOff` / `.bluetoothDenied`
    /// when Bluetooth went; `.protocolFailure` when the stream can't be framed.
    func receive() async throws -> [UInt8] {
        guard let pipe = state.withLock({ $0.pipe }) else { throw ReGlassError.linkLost }
        return try await pipe.frames.next()
    }

    func close() {
        let (pipe, watch, holdsConnection, wasOpen) = state.withLock { state in
            defer {
                state.isClosed = true
                state.pipe = nil
                state.watch = nil
                state.holdsConnection = false
            }
            return (state.pipe, state.watch, state.holdsConnection, !state.isClosed)
        }
        closed.resolve(.success(()))
        if let watch { central.stopWatching(watch) }
        if let pipe {
            Self.history.withLock { $0[glasses, default: ChannelHistory()].closedAt = .now }
            pipe.close(throwing: .linkLost)
            if wasOpen { kitLog("bluetooth", "L2CAP closed to \(BluetoothCentral.label(glasses))") }
        }
        if holdsConnection { central.release(glasses, holder: holder) }
    }

    // MARK: Opening

    /// Whatever this acquires is recorded in `state` as it goes, so `close()` lets go of it whenever the attempt ends.
    private func open() async throws {
        try await central.waitUntilPoweredOn(timeout: Self.powerTimeout)
        try await central.connect(glasses, holder: holder, timeout: Self.connectTimeout)
        try keep { $0.holdsConnection = true }
        let psm = await channelPSM()
        try await waitForPreviousChannel()
        let channel = try await openChannel(psm: psm)
        let pipe = L2CAPPipe(channel: channel)
        await pipe.start()
        try keep { $0.pipe = pipe }
        let watch = central.watchLink(glasses) { pipe.close(throwing: $0) }
        try keep { $0.watch = watch }
        try Task.checkCancellation()
    }

    /// Records what `open` acquired, unless the transport closed meanwhile; then `connect`'s `close()` lets it go.
    private func keep(_ update: (inout State) -> Void) throws {
        let isClosed = state.withLock { state -> Bool in
            update(&state)
            return state.isClosed
        }
        if isClosed { throw ReGlassError.linkLost }
    }

    /// The PSM read earlier, else the one the glasses' PSM characteristic names, else Meta's default.
    private func channelPSM() async -> UInt16 {
        if let known = Self.history.withLock({ $0[glasses]?.psm }) { return known }
        let raw: [UInt8]?
        do {
            raw = try await withTimeout(Self.psmReadTimeout, "PSM read") { [central, glasses] in
                try await central.readValue(of: MetaGatt.psmCharacteristic, in: MetaGatt.service, on: glasses,
                                            timeout: BluetoothCentral.gattTimeout)
            }
        } catch is CancellationError {
            return MetaGatt.defaultPSM
        } catch {
            kitLog("bluetooth", "PSM read failed (\(logDescription(error))); using psm \(MetaGatt.defaultPSM) (default)")
            return MetaGatt.defaultPSM
        }
        guard let psm = raw.flatMap(MetaGatt.channelPSM(from:)) else {
            kitLog("bluetooth", "PSM read: \(raw == nil ? "no PSM characteristic" : "no PSM in its \(raw?.count ?? 0) bytes"); "
                     + "using psm \(MetaGatt.defaultPSM) (default)")
            return MetaGatt.defaultPSM
        }
        kitLog("bluetooth", "PSM read: using psm \(psm) (from the glasses)")
        Self.history.withLock { $0[glasses, default: ChannelHistory()].psm = psm }
        return psm
    }

    private func waitForPreviousChannel() async throws {
        guard let closedAt = Self.history.withLock({ $0[glasses]?.closedAt }) else { return }
        let remaining = ContinuousClock.now.duration(to: closedAt + Self.reopenGap)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        try Task.checkCancellation()
    }

    /// Opens the channel, once more after a short wait if iOS still holds the previous one on this PSM. A PSM that
    /// won't open is forgotten, so the next attempt reads it again.
    private func openChannel(psm: UInt16) async throws -> CBL2CAPChannel {
        let deadline = ContinuousClock.now + Self.stillClosingLimit
        var waited = false
        do {
            while true {
                do {
                    return try await central.openChannel(psm: psm, on: glasses, timeout: Self.channelTimeout)
                } catch is ChannelStillClosing {
                    // iOS still holds the previous channel on this PSM. Keep knocking until it frees, so the open
                    // lands the moment it does rather than after the session's whole-attempt backoff.
                    guard ContinuousClock.now < deadline else { throw ReGlassError.noAnswer }
                    if !waited {
                        kitLog("bluetooth", "the previous L2CAP channel is still closing; retrying until it frees")
                        waited = true
                    }
                    try await Task.sleep(for: Self.stillClosingRetryDelay)
                }
            }
        } catch {
            Self.history.withLock { $0[glasses]?.psm = nil }
            throw error
        }
    }
}
