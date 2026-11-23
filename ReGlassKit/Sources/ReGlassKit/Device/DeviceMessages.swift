import Foundation

/// The parts of an svc28 DeviceState message ReGlass shows. Every field is optional: a push names only what changed,
/// and an absent protobuf field must never read as 0 % battery.
struct DeviceStateReading: Equatable, Sendable {
    var batteryPercent: Int?
    var charging: Bool?
    var caseBatteryPercent: Int?
    var caseCharging: Bool?
    /// The case reports the glasses in it.
    var inCase: Bool?
    var worn: Bool?

    /// Decodes a DeviceState payload (the 2005 snapshot or any single-field push; they share one layout).
    ///
    /// Battery (field 1): charge state 2, percent 3 — the percent counts only when present and 0–100.
    /// Case (field 2): charging 2, level 3, scale 7 (4 when absent), present 8 — a percent only on a 0–100 scale.
    /// Mount (field 9): 1 worn, 2 not worn.
    static func decode(_ payload: [UInt8]) throws -> DeviceStateReading {
        let top = try Wire.parse(payload)
        var reading = DeviceStateReading()
        if top.has(1) {
            let battery = try Wire.parse(top.bytes(1))
            let percent = battery.varint(3, -1)
            if (0...100).contains(percent) { reading.batteryPercent = Int(percent) }
            let chargeState = battery.varint(2)
            if chargeState != 0 { reading.charging = (1...3).contains(chargeState) }   // 0 = no data
        }
        if top.has(2) {
            let box = try Wire.parse(top.bytes(2))
            let level = Int64(Int32(truncatingIfNeeded: box.varint(3)))
            let scale = box.varint(7) != 0 ? box.varint(7) : 4
            if level >= 0 && level <= scale {
                reading.inCase = box.varint(8) != 0
                reading.caseCharging = box.varint(2) != 0
                if scale == 100 { reading.caseBatteryPercent = Int(level) }
            }
        }
        if top.has(9) {
            switch top.varint(9) {
            case 1: reading.worn = true
            case 2: reading.worn = false
            default: break
            }
        }
        return reading
    }

    /// svc28 message types that carry a DeviceState: the 2005 snapshot and the per-field pushes after it.
    static func isDeviceState(_ messageType: Int) -> Bool {
        (2005...2037).contains(messageType) || (2039...2044).contains(messageType)
    }
}

/// The svc100 reply (message 3) gives the firmware build (field 1), serial (2), model (8), all ISO-8859-1, and the
/// reply bitrate the glasses prefer for the assistant's CELT audio (12; absent or 0 means not said).
struct PeerDeviceInfo: Equatable, Sendable {
    let firmware: String
    let serial: String
    let model: String
    var preferredReplyBitrate: Int?

    static func decode(_ payload: [UInt8]) throws -> PeerDeviceInfo {
        let fields = try Wire.parse(payload)
        func latin1(_ bytes: [UInt8]) -> String {
            var scalars = String.UnicodeScalarView()
            for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
            return String(scalars)
        }
        let bitrate = fields.varint(12)
        return PeerDeviceInfo(firmware: latin1(fields.bytes(1)), serial: latin1(fields.bytes(2)),
                              model: latin1(fields.bytes(8)),
                              preferredReplyBitrate: bitrate > 0 ? Int(exactly: bitrate) : nil)
    }
}

/// The glasses persist these svc31 message 2 settings until a factory reset.
/// - Tag 80 controls Adaptive Volume (varint 0 or 1, default 1).
/// - Tag 286 controls head-tracked Spatial Audio (varint 0 or 4, default 4).
/// - Tag 2 enables the assistant (varint 0 or 1).
/// - Tag 36 enables "Hey Meta" detection (varint 0 or 1). The glasses need this setting
///   enabled even when the wake word model is installed.
public struct GlassesAudioSettings: Equatable, Sendable {
    public var adaptiveVolume: Bool?
    public var spatialAudio: Bool?
    public var assistantEnabled: Bool?
    public var wakeWordEnabled: Bool?

    public init(adaptiveVolume: Bool? = nil, spatialAudio: Bool? = nil, assistantEnabled: Bool? = nil,
                wakeWordEnabled: Bool? = nil) {
        self.adaptiveVolume = adaptiveVolume
        self.spatialAudio = spatialAudio
        self.assistantEnabled = assistantEnabled
        self.wakeWordEnabled = wakeWordEnabled
    }

    func encode() throws -> [UInt8] {
        var bytes: [UInt8] = []
        if let assistantEnabled {
            bytes += try Wire.fieldVarint(2, assistantEnabled ? 1 : 0)
        }
        if let wakeWordEnabled {
            bytes += try Wire.fieldVarint(36, wakeWordEnabled ? 1 : 0)
        }
        if let adaptiveVolume {
            bytes += try Wire.fieldVarint(80, adaptiveVolume ? 1 : 0)
        }
        if let spatialAudio {
            bytes += try Wire.fieldVarint(286, spatialAudio ? 4 : 0)
        }
        return bytes
    }

    static func decodeSuccess(_ payload: [UInt8]) -> Bool {
        guard let fields = try? Wire.parse(payload) else { return false }
        return fields.varint(1) == 2
    }
}

/// Requests the phone sends in order once the link is ready.
enum DeviceRequests {
    /// Send an empty svc100 message 1 to ask the glasses for their build information in message 3.
    static func announce(_ mux: DataXMultiplexer) async throws {
        let channel = await mux.openChannel(DataXService.peerBuildInfo)
        try await mux.send(channel, [], messageType: PeerBuildInfoMessageType.peerAppInfo,
                           serviceId: DataXService.peerBuildInfo)
    }

    /// svc28 CompanionDeviceInit on `channel` (a new one when nil): a full DeviceState snapshot, then pushes.
    /// Asking again on the same channel only brings a fresh snapshot; a new channel would duplicate every push.
    @discardableResult
    static func subscribe(_ mux: DataXMultiplexer, on channel: Int?) async throws -> Int {
        let interactionKey = UUID().uuidString.lowercased()
        let payload = Wire.fieldBytes(1, try Wire.encodeVarint(deviceStateSubscription))
            + Wire.fieldBytes(2, Array(interactionKey.utf8))
        let target: Int
        if let channel { target = channel } else { target = await mux.openChannel(DataXService.status) }
        try await mux.send(target, payload, messageType: StatusMessageType.initialize, serviceId: DataXService.status)
        return target
    }

    /// svc22 DeviceInfoRequest `{1: {1: seconds, 2: nanos}, 2: time zone id, 3: request uuid}`: sets the glasses'
    /// clock and time zone to the phone's. Nothing else sets them.
    static func syncClock(_ mux: DataXMultiplexer, now: Date = Date(), zone: TimeZone = .current) async throws {
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let (quotient, remainder) = millis.quotientAndRemainder(dividingBy: 1000)
        let seconds = remainder < 0 ? quotient - 1 : quotient
        let subMillis = remainder < 0 ? remainder + 1000 : remainder
        let uuid = UUID().uuid
        let requestID: [UInt8] = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                                  uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15]
        let timestamp = try Wire.fieldVarint(1, seconds) + Wire.fieldVarint(2, subMillis * 1_000_000)
        let payload = Wire.fieldBytes(1, timestamp) + Wire.fieldBytes(2, Array(zone.identifier.utf8))
            + Wire.fieldBytes(3, requestID)
        let channel = await mux.openChannel(DataXService.deviceInfo)
        try await mux.send(channel, payload, messageType: DeviceInfoMessageType.deviceInfoRequest,
                           serviceId: DataXService.deviceInfo)
    }

    /// The three READY requests as one piece of work, so they go out in order. Returns the svc28 channel.
    static func onReady(_ mux: DataXMultiplexer) async throws -> Int {
        try await announce(mux)
        let statusChannel = try await subscribe(mux, on: nil)
        try await syncClock(mux)
        return statusChannel
    }
}
