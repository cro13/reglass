import CoreBluetooth
import Foundation

/// One party that wants a pair's LE connection up. The central re-requests the connection after every drop for as
/// long as a `reconnects` holder holds it; other holders keep it only while they use it.
struct ConnectionHolder: Hashable, Sendable {
    let role: String
    let reconnects: Bool
    private let token = UUID()

    init(role: String, reconnects: Bool) {
        self.role = role
        self.reconnects = reconnects
    }
}

/// A Meta characteristic as discovered: enough to decide whether to read it.
struct CharacteristicSummary {
    let uuid: CBUUID
    let isReadable: Bool
    var canNotify = false
}

/// The app's one CoreBluetooth central. iOS gives an app one manager per restoration identifier and one connection
/// per peripheral, so the finder, the keeper and every transport share it. It is the delegate of every peripheral
/// it touches and turns their callbacks into async calls.
///
/// `@unchecked Sendable`: all mutable state is read and written only on `queue`, the serial queue CoreBluetooth calls
/// the delegates on. Async callers hop onto it and wait on a `OneShot`, answered exactly once: by the callback, the
/// operation's timeout, a disconnect, or Bluetooth going away; the caller's cancellation ends the wait early.
final class BluetoothCentral: NSObject, @unchecked Sendable {
    static let shared = BluetoothCentral()

    /// Each GATT step (service or characteristic discovery, a read unless the caller says otherwise).
    static let gattTimeout: Duration = .seconds(10)
    /// After a held connection fails to come up, before asking again.
    static let reconnectDelay: Duration = .seconds(5)

    private let queue = DispatchQueue(label: "reglass.bluetooth")
    /// The manager's last reported state, readable from anywhere without a hop onto the queue.
    private let reportedState = Locked(CBManagerState.unknown)
    private var manager: CBCentralManager?
    /// Peripherals this central is the delegate of, kept alive: iOS drops a connection whose peripheral object goes.
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Who wants each connection up. When the last holder lets go, the app's connection is cancelled.
    private var holders: [UUID: Set<ConnectionHolder>] = [:]
    /// Connections this central cancelled whose disconnect iOS hasn't reported yet: their state may still read
    /// `.connected`, so nothing may join them.
    private var closing: Set<UUID> = []
    private var pending: [Operation: [OneShot<Reply>]] = [:]
    private var scanners: [UUID: AsyncThrowingStream<Advertisement, Error>.Continuation] = [:]
    private var linkWatchers: [UUID: LinkWatcher] = [:]
    /// Connections with the wake subscription on (see `ensureWakeSubscription`), and ones setting it up.
    private var subscribed: Set<UUID> = []
    private var subscribing: Set<UUID> = []
    /// When this process created the central, and whether a notification has come since (logged once).
    private let startedAt = Date()
    private var heardNotification = false

    private override init() {
        super.init()
    }

    // MARK: Lifecycle

    /// Creates the manager. Synchronous, so iOS's state restoration finds it before `didFinishLaunching` returns.
    func start() {
        queue.sync { _ = makeManager() }
    }

    /// The radio's state as last reported; `.unknown` until the central has started and heard from iOS.
    var state: CBManagerState { reportedState.current }

    static var authorization: CBManagerAuthorization { CBManager.authorization }

    /// Returns once Bluetooth is on. Throws `.bluetoothOff`, `.bluetoothDenied` or `.bluetoothUnsupported` as soon as
    /// that is certain, or when `timeout` passes first.
    func waitUntilPoweredOn(timeout: Duration) async throws {
        _ = try await perform(.powerOn, timeout: timeout, onTimeout: { [self] in
            ReGlassError.unavailable(manager?.state ?? .unknown, afterWaiting: true) ?? .bluetoothOff
        }) { [self] in
            let state = makeManager().state
            if state == .poweredOn { return .done }
            if let failure = ReGlassError.unavailable(state) { throw failure }
            return nil
        }
    }

    // MARK: Finding glasses

    /// Glasses with Meta's service that iOS itself holds a link to (paired with this iPhone). They may not advertise.
    func glassesConnectedToPhone() async -> [(id: UUID, name: String?)] {
        await onQueue { [self] in
            guard let manager, manager.state == .poweredOn else { return [] }
            return manager.retrieveConnectedPeripherals(withServices: [MetaGatt.service]).map { ($0.identifier, $0.name) }
        }
    }

    /// Every advert heard while the stream is consumed. The scan has no filter (offloaded filters miss some glasses)
    /// and reports duplicates, so signal strength stays current. Finishes with the Bluetooth error when Bluetooth goes.
    func advertisements() -> AsyncThrowingStream<Advertisement, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let token = UUID()
            // Enqueued before any termination can be, so `stopScanning` always runs after this.
            queue.async { [self] in
                let manager = makeManager()
                guard manager.state == .poweredOn else {
                    continuation.finish(throwing: ReGlassError.unavailable(manager.state, afterWaiting: true) ?? .bluetoothOff)
                    return
                }
                scanners[token] = continuation
                if scanners.count == 1 {
                    kitLog("bluetooth", "scanning")
                    manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                }
            }
            continuation.onTermination = { [self] _ in
                queue.async { [self] in stopScanning(token) }
            }
        }
    }

    private func stopScanning(_ token: UUID) {
        guard scanners.removeValue(forKey: token) != nil, scanners.isEmpty,
              let manager, manager.state == .poweredOn, manager.isScanning else { return }
        manager.stopScan()
        kitLog("bluetooth", "scan stopped")
    }

    // MARK: Connections

    /// Connects (or joins the connection that is up) and keeps it for `holder` until `release`. Throws `.noAnswer`
    /// after `timeout`, `.pairingDeclined` when iOS reports a pairing failure, `.glassesUnknown` when iOS no longer
    /// knows the peripheral, or a Bluetooth error. The hold is dropped on any failure, cancellation included.
    func connect(_ id: UUID, holder: ConnectionHolder, timeout: Duration) async throws {
        do {
            _ = try await perform(.connect(id), timeout: timeout, onTimeout: {
                kitLog("bluetooth", "no LE connection to \(Self.label(id)) in \(timeout)")
                return ReGlassError.noAnswer
            }) { [self] in
                let manager = try poweredOnManager()
                let peripheral = try knownPeripheral(id)
                holders[id, default: []].insert(holder)
                if isClosing(peripheral) {
                    // The pairing step's connection, say, still going down. The disconnect asks for this one.
                    kitLog("bluetooth", "connecting \(Self.label(id)) for the \(holder.role) once the last connection closes")
                    return nil
                }
                if peripheral.state == .connected { return .done }
                kitLog("bluetooth", "connecting \(Self.label(id)) for the \(holder.role)")
                manager.connect(peripheral)
                return nil
            }
        } catch {
            release(id, holder: holder)
            throw error
        }
    }

    /// Holds the connection for a `reconnects` holder: a request with no deadline that iOS completes whenever the
    /// glasses are in reach, issued again after every drop, failure and Bluetooth restart until `release`.
    func keepConnected(_ id: UUID, holder: ConnectionHolder) {
        queue.async { [self] in
            _ = makeManager()
            if holders[id, default: []].insert(holder).inserted {
                kitLog("bluetooth", "holding the connection to \(Self.label(id))")
            }
            requestConnection(id)
        }
    }

    /// Drops `holder`'s hold. With nobody left holding, the app's connection is cancelled; iOS keeps its own link to
    /// glasses paired as a headset.
    func release(_ id: UUID, holder: ConnectionHolder) {
        queue.async { [self] in
            guard holders[id]?.remove(holder) != nil else { return }
            guard holders[id]?.isEmpty == true else { return }
            holders[id] = nil
            if let manager, manager.state == .poweredOn, let peripheral = peripherals[id], peripheral.state != .disconnected {
                kitLog("bluetooth", "closing the LE connection to \(Self.label(id))")
                closing.insert(id)
                manager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    /// Asks iOS for the connection when a `reconnects` holder or a waiting `connect` wants it.
    private func requestConnection(_ id: UUID) {
        let wanted = holders[id]?.contains(where: \.reconnects) == true || pending[.connect(id)] != nil
        guard wanted, let manager, manager.state == .poweredOn else { return }
        do {
            let peripheral = try knownPeripheral(id)
            // A connection still closing is asked for again by its disconnect.
            if peripheral.state != .connected, !isClosing(peripheral) { manager.connect(peripheral) }
            // Already up (restored by iOS, say): no didConnect will come to set the subscription.
            if peripheral.state == .connected { ensureWakeSubscription(id) }
        } catch {
            kitLog("bluetooth", "can't hold \(Self.label(id)): iOS no longer knows these glasses")
        }
    }

    /// True while a connection this central cancelled hasn't been reported closed.
    private func isClosing(_ peripheral: CBPeripheral) -> Bool {
        guard closing.contains(peripheral.identifier) else { return false }
        guard peripheral.state != .disconnected else {
            closing.remove(peripheral.identifier)
            return false
        }
        return true
    }

    /// Calls `onLoss` (on the central's queue) when the LE link to `id` drops or Bluetooth goes, including when it is
    /// already down. Returns a token for `stopWatching`.
    func watchLink(_ id: UUID, onLoss: @escaping @Sendable (ReGlassError) -> Void) -> UUID {
        let token = UUID()
        queue.async { [self] in
            linkWatchers[token] = LinkWatcher(peripheral: id, onLoss: onLoss)
            if let failure = ReGlassError.unavailable(manager?.state ?? .unknown, afterWaiting: true) {
                onLoss(failure)
            } else if peripherals[id]?.state != .connected {
                onLoss(.linkLost)
            }
        }
        return token
    }

    func stopWatching(_ token: UUID) {
        queue.async { [self] in linkWatchers[token] = nil }
    }

    // MARK: GATT and L2CAP

    /// Meta's characteristics in `service`, discovering them; nil when the glasses don't have the service.
    func characteristics(in service: CBUUID, on id: UUID) async throws -> [CharacteristicSummary]? {
        guard try await discover(service, on: id) else { return nil }
        return try await discoverCharacteristics(nil, in: service, on: id)
    }

    /// Reads `characteristic`, discovering it first if needed; nil when the glasses don't have it. A characteristic
    /// that needs encryption makes iOS pair first (its own prompt), which takes as long as the person takes.
    func readValue(of characteristic: CBUUID, in service: CBUUID, on id: UUID, timeout: Duration) async throws -> [UInt8]? {
        guard try await discover(service, on: id),
              try await discoverCharacteristics([characteristic], in: service, on: id).contains(where: { $0.uuid == characteristic })
        else { return nil }
        let reply = try await perform(.read(id, service: GattKey(service), characteristic: GattKey(characteristic)),
                                      timeout: timeout, onTimeout: { ReGlassError.timedOut("characteristic read") }) { [self] in
            let peripheral = try connectedPeripheral(id)
            guard let found = peripheral.services?.first(where: { $0.uuid == service })?
                .characteristics?.first(where: { $0.uuid == characteristic }) else { throw ReGlassError.noAnswer }
            peripheral.readValue(for: found)
            return nil
        }
        return reply.bytes
    }

    /// Opens an LE credit-based channel on the connected glasses. iOS picks the link security itself. Throws
    /// `.noAnswer` after `timeout` or when refused, `.pairingDeclined` for a pairing failure, `ChannelStillClosing`
    /// when iOS still holds the previous channel on this PSM, `.linkLost` when not connected.
    func openChannel(psm: UInt16, on id: UUID, timeout: Duration) async throws -> CBL2CAPChannel {
        let reply = try await perform(.channel(id), timeout: timeout, onTimeout: {
            kitLog("bluetooth", "L2CAP psm \(psm) didn't open in \(timeout)")
            return ReGlassError.noAnswer
        }) { [self] in
            let peripheral = try connectedPeripheral(id)
            kitLog("bluetooth", "opening L2CAP psm \(psm) to \(Self.label(id))")
            peripheral.openL2CAPChannel(psm)
            return nil
        }
        return reply.channel
    }

    /// Turns on notifications for `characteristic`, discovering it first if needed. False when the glasses don't have
    /// it or it can't notify.
    func subscribe(to characteristic: CBUUID, in service: CBUUID, on id: UUID) async throws -> Bool {
        guard try await discover(service, on: id),
              try await discoverCharacteristics([characteristic], in: service, on: id)
                .contains(where: { $0.uuid == characteristic && $0.canNotify })
        else { return false }
        _ = try await perform(.notify(id, characteristic: GattKey(characteristic)), timeout: Self.gattTimeout,
                              onTimeout: { ReGlassError.timedOut("notification subscription") }) { [self] in
            let peripheral = try connectedPeripheral(id)
            guard let found = peripheral.services?.first(where: { $0.uuid == service })?
                .characteristics?.first(where: { $0.uuid == characteristic }) else { throw ReGlassError.noAnswer }
            if found.isNotifying { return .done }
            peripheral.setNotifyValue(true, for: found)
            return nil
        }
        return true
    }

    /// iOS relaunches an app it ended only for a Bluetooth event it was waiting for (TN3115). The glasses' LE link
    /// outlives ReGlass (iOS keeps it up for audio) and the wake word arrives on ReGlass's own L2CAP channel, which ends
    /// with the process, so neither gives iOS a reason, and a wake word then finds no assistant. The glasses notify
    /// their PSM characteristic when the assistant's session disappears (seen on hardware: the app relaunched 1.2 s
    /// after being ended, before the wearer spoke), so this subscription gives iOS that event. It only turns
    /// notifications on; nothing on the glasses changes. For connections a `reconnects` holder (the keeper) holds, once
    /// per connection.
    private func ensureWakeSubscription(_ id: UUID) {
        guard holders[id]?.contains(where: \.reconnects) == true,
              !subscribed.contains(id), subscribing.insert(id).inserted else { return }
        Task { [self] in
            var done = false
            let note: String
            do {
                done = try await subscribe(to: MetaGatt.psmCharacteristic, in: MetaGatt.service, on: id)
                note = done ? "subscribed to the glasses' PSM notifications, so iOS can relaunch ReGlass if it ends it"
                    : "the glasses offer no PSM notifications; iOS can't relaunch ReGlass if it ends it"
            } catch {
                note = "PSM notifications not set (\(logDescription(error))); tried again on the next connection"
            }
            queue.async { [self] in
                subscribing.remove(id)
                if done { subscribed.insert(id) }
            }
            kitLog("bluetooth", note)
        }
    }

    /// Discovers `service` unless it is known already; false when the glasses don't have it.
    private func discover(_ service: CBUUID, on id: UUID) async throws -> Bool {
        let reply = try await perform(.services(id), timeout: Self.gattTimeout,
                                      onTimeout: { ReGlassError.timedOut("service discovery") }) { [self] in
            let peripheral = try connectedPeripheral(id)
            if let known = peripheral.services, known.contains(where: { $0.uuid == service }) {
                return .services(known.map(\.uuid))
            }
            peripheral.discoverServices([service])
            return nil
        }
        return reply.services.contains(service)
    }

    /// Discovers characteristics of a discovered `service`: `uuids`, unless all are known already, or all of them.
    private func discoverCharacteristics(_ uuids: [CBUUID]?, in service: CBUUID, on id: UUID) async throws -> [CharacteristicSummary] {
        let reply = try await perform(.characteristics(id, service: GattKey(service)), timeout: Self.gattTimeout,
                                      onTimeout: { ReGlassError.timedOut("characteristic discovery") }) { [self] in
            let peripheral = try connectedPeripheral(id)
            guard let found = peripheral.services?.first(where: { $0.uuid == service }) else { throw ReGlassError.noAnswer }
            if let uuids, let known = found.characteristics, uuids.allSatisfy({ uuid in known.contains { $0.uuid == uuid } }) {
                return .characteristics(Self.summaries(found))
            }
            peripheral.discoverCharacteristics(uuids, for: found)
            return nil
        }
        return reply.characteristics
    }

    // MARK: Waiting

    /// What a caller waits for. Service and characteristic keys are `GattKey`s, never `uuidString`s: a request
    /// starts from the caller's UUID and its callback from CoreBluetooth's object, which spell one UUID differently.
    private enum Operation: Hashable {
        case powerOn
        case connect(UUID)
        case services(UUID)
        case characteristics(UUID, service: GattKey)
        case read(UUID, service: GattKey, characteristic: GattKey)
        case notify(UUID, characteristic: GattKey)
        case channel(UUID)

        var peripheral: UUID? {
            switch self {
            case .powerOn: return nil
            case .connect(let id), .services(let id), .channel(let id),
                 .characteristics(let id, _), .read(let id, _, _), .notify(let id, _): return id
            }
        }
    }

    /// Each operation is only ever answered with its own kind of reply, so the accessors can't miss.
    private enum Reply {
        case done
        case services([CBUUID])
        case characteristics([CharacteristicSummary])
        case bytes([UInt8])
        case channel(CBL2CAPChannel)

        var services: [CBUUID] {
            guard case .services(let uuids) = self else { preconditionFailure("not a service reply") }
            return uuids
        }

        var characteristics: [CharacteristicSummary] {
            guard case .characteristics(let found) = self else { preconditionFailure("not a characteristic reply") }
            return found
        }

        var bytes: [UInt8] {
            guard case .bytes(let value) = self else { preconditionFailure("not a read reply") }
            return value
        }

        var channel: CBL2CAPChannel {
            guard case .channel(let channel) = self else { preconditionFailure("not a channel reply") }
            return channel
        }
    }

    private struct LinkWatcher {
        let peripheral: UUID
        let onLoss: @Sendable (ReGlassError) -> Void
    }

    /// Runs `start` on the queue and waits for the reply. `start` answers at once by returning a reply or throwing,
    /// or returns nil to wait for the delegate callback, which answers every waiter on `operation`.
    private func perform(
        _ operation: Operation,
        timeout: Duration,
        onTimeout: @escaping () -> Error,
        start: @escaping () throws -> Reply?
    ) async throws -> Reply {
        let reply = OneShot<Reply>()
        queue.async { [self] in
            do {
                if let immediate = try start() {
                    reply.resolve(.success(immediate))
                    return
                }
            } catch {
                reply.resolve(.failure(error))
                return
            }
            pending[operation, default: []].append(reply)
            queue.asyncAfter(deadline: .now() + timeout.dispatchInterval) { [self] in
                guard !reply.isResolved else { return }
                reply.resolve(.failure(onTimeout()))
                pending[operation]?.removeAll { $0 === reply }
                if pending[operation]?.isEmpty == true { pending[operation] = nil }
            }
        }
        return try await reply.value()
    }

    private func answer(_ operation: Operation, _ result: Result<Reply, Error>) {
        for reply in pending.removeValue(forKey: operation) ?? [] { reply.resolve(result) }
    }

    private func answer(_ operation: Operation, _ reply: Reply, orFailure error: Error?) {
        answer(operation, error.map { .failure($0) } ?? .success(reply))
    }

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: Plumbing

    private func makeManager() -> CBCentralManager {
        if let manager { return manager }
        var options: [String: Any] = [:]
        // Asking for restoration without the bluetooth-central background mode is a crash.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("bluetooth-central") {
            options[CBCentralManagerOptionRestoreIdentifierKey] = GlassesBluetooth.restoreIdentifier
        }
        let made = CBCentralManager(delegate: self, queue: queue, options: options)
        manager = made
        kitLog("bluetooth", options.isEmpty ? "central created without state restoration" : "central created")
        return made
    }

    private func poweredOnManager() throws -> CBCentralManager {
        let manager = makeManager()
        guard manager.state == .poweredOn else {
            throw ReGlassError.unavailable(manager.state, afterWaiting: true) ?? .bluetoothOff
        }
        return manager
    }

    /// The peripheral iOS knows as `id`: by identifier, among the glasses it holds a link to, or one this central
    /// already has (restored). Throws `.glassesUnknown` when iOS no longer knows it. Needs Bluetooth on.
    private func knownPeripheral(_ id: UUID) throws -> CBPeripheral {
        guard let manager else { throw ReGlassError.bluetoothOff }
        let found = manager.retrievePeripherals(withIdentifiers: [id]).first
            ?? manager.retrieveConnectedPeripherals(withServices: [MetaGatt.service]).first { $0.identifier == id }
            ?? peripherals[id]
        guard let found else { throw ReGlassError.glassesUnknown }
        adopt(found)
        return found
    }

    private func connectedPeripheral(_ id: UUID) throws -> CBPeripheral {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { throw ReGlassError.linkLost }
        return peripheral
    }

    private func adopt(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        if peripheral.delegate !== self { peripheral.delegate = self }
    }

    /// Fails every wait on `id` except its connect, which a disconnect doesn't decide.
    private func failOperations(on id: UUID, _ error: ReGlassError) {
        for operation in Array(pending.keys) where operation.peripheral == id && operation != .connect(id) {
            answer(operation, .failure(error))
        }
    }

    private static func summaries(_ service: CBService) -> [CharacteristicSummary] {
        (service.characteristics ?? []).map {
            CharacteristicSummary(uuid: $0.uuid, isReadable: $0.properties.contains(.read),
                                  canNotify: !$0.properties.isDisjoint(with: [.notify, .indicate]))
        }
    }

    /// A log-safe name for a peripheral: a short prefix of its identifier.
    static func label(_ id: UUID) -> String {
        "glasses \(id.uuidString.prefix(8))"
    }
}

/// A GATT UUID as a wait key: all 128 bits, a 16- or 32-bit UUID expanded onto the Bluetooth base UUID. CoreBluetooth
/// spells one UUID two ways (the glasses' service object reads "FD5F", `MetaGatt.service` the long form); CBUUID
/// equality treats both as one, but their `uuidString`s differ, so a key built from those would never match.
struct GattKey: Hashable {
    private let bytes: [UInt8]

    init(_ uuid: CBUUID) {
        let short = uuid.data.byteArray
        switch short.count {
        case 2: bytes = [0, 0] + short + Self.baseTail
        case 4: bytes = short + Self.baseTail
        default: bytes = short
        }
    }

    /// Bytes 4–15 of the Bluetooth base UUID, 00000000-0000-1000-8000-00805F9B34FB.
    private static let baseTail: [UInt8] = [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB]
}

// MARK: - CBCentralManagerDelegate

extension BluetoothCentral: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        let restored = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restored.forEach(adopt)
        let described = restored.map { "\(Self.label($0.identifier)) \($0.state.logName)" }.joined(separator: ", ")
        kitLog("bluetooth", "iOS restored the central" + (described.isEmpty ? "" : ": \(described)"))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        reportedState.withLock { $0 = state }
        kitLog("bluetooth", "Bluetooth \(state.logName)")
        if state == .poweredOn {
            answer(.powerOn, .success(.done))
            // iOS dropped pending connection requests with the radio: ask again.
            for id in holders.keys { requestConnection(id) }
            return
        }
        if let failure = ReGlassError.unavailable(state) { answer(.powerOn, .failure(failure)) }
        // iOS drops every connection with the radio, and no disconnect callback says so.
        closing.removeAll()
        let lost = ReGlassError.unavailable(state, afterWaiting: true) ?? .bluetoothOff
        for operation in Array(pending.keys) where operation != .powerOn { answer(operation, .failure(lost)) }
        for watcher in linkWatchers.values { watcher.onLoss(lost) }
        for scanner in scanners.values { scanner.finish(throwing: lost) }
        scanners.removeAll()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard !scanners.isEmpty else { return }
        let advertisement = Advertisement(peripheral: peripheral, data: advertisementData, rssi: rssi.intValue)
        for scanner in scanners.values { scanner.yield(advertisement) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        closing.remove(peripheral.identifier)
        adopt(peripheral)
        kitLog("bluetooth", "connected \(Self.label(peripheral.identifier))")
        answer(.connect(peripheral.identifier), .success(.done))
        ensureWakeSubscription(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        closing.remove(id)
        kitLog("bluetooth", "couldn't connect \(Self.label(id))" + (error.map { ": \(logDescription($0))" } ?? ""))
        answer(.connect(id), .failure(error.map(isPairingFailure) == true ? ReGlassError.pairingDeclined : .noAnswer))
        if holders[id]?.contains(where: \.reconnects) == true {
            queue.asyncAfter(deadline: .now() + Self.reconnectDelay.dispatchInterval) { [self] in requestConnection(id) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        closing.remove(id)
        subscribed.remove(id)
        kitLog("bluetooth", "disconnected \(Self.label(id))" + (error.map { ": \(logDescription($0))" } ?? ""))
        failOperations(on: id, .linkLost)
        for watcher in linkWatchers.values where watcher.peripheral == id { watcher.onLoss(.linkLost) }
        requestConnection(id)
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { kitLog("bluetooth", "service discovery failed: \(logDescription(error))") }
        answer(.services(peripheral.identifier), .services(peripheral.services?.map(\.uuid) ?? []), orFailure: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { kitLog("bluetooth", "characteristic discovery failed: \(logDescription(error))") }
        answer(.characteristics(peripheral.identifier, service: GattKey(service.uuid)),
               .characteristics(Self.summaries(service)), orFailure: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { kitLog("bluetooth", "notification subscription failed: \(logDescription(error))") }
        answer(.notify(peripheral.identifier, characteristic: GattKey(characteristic.uuid)), .done, orFailure: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { kitLog("bluetooth", "read failed: \(logDescription(error))") }
        let id = peripheral.identifier
        let target = GattKey(characteristic.uuid)
        let value = characteristic.value?.byteArray ?? []
        if characteristic.isNotifying, error == nil {
            if !heardNotification {
                // After iOS relaunched ReGlass, this says whether the glasses' notification was the reason.
                heardNotification = true
                kitLog("bluetooth", "first notification from the glasses since ReGlass started, "
                         + String(format: "%.1f s after launch", Date().timeIntervalSince(startedAt)))
            }
            // A notification looks just like a read reply. The glasses notify their PSM on connection and a one-byte
            // 00 every few seconds during a voice turn; one with no PSM in it mustn't answer a PSM read, or the link
            // would open the default PSM instead of theirs.
            if characteristic.uuid == MetaGatt.psmCharacteristic, MetaGatt.channelPSM(from: value) == nil { return }
        }
        let reply = Reply.bytes(value)
        if let service = characteristic.service {
            answer(.read(id, service: GattKey(service.uuid), characteristic: target), reply, orFailure: error)
            return
        }
        // The service object is gone (its services changed): answer this characteristic's reads in any service.
        for operation in Array(pending.keys) {
            if case .read(id, _, target) = operation { answer(operation, reply, orFailure: error) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        let operation = Operation.channel(peripheral.identifier)
        if let channel, error == nil {
            kitLog("bluetooth", "L2CAP psm \(channel.psm) open to \(Self.label(peripheral.identifier))")
            answer(operation, .success(.channel(channel)))
            return
        }
        kitLog("bluetooth", "L2CAP didn't open" + (error.map { ": \(logDescription($0))" } ?? ""))
        let failure: Error
        if let error, isChannelStillClosing(error) {
            failure = ChannelStillClosing()
        } else {
            failure = error.map(isPairingFailure) == true ? ReGlassError.pairingDeclined : ReGlassError.noAnswer
        }
        answer(operation, .failure(failure))
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
