import Foundation

/// A pair of Meta glasses the iPhone can reach: held by iOS, or heard advertising.
public struct NearbyGlasses: Identifiable, Equatable, Sendable {
    /// The CoreBluetooth peripheral identifier.
    public let id: UUID
    /// The advertised name, e.g. "RB Meta 00B2".
    public var name: String
    /// Nil for glasses iOS holds a link to that aren't advertising.
    public var rssi: Int?
    /// iOS holds a link to them: they are paired with this iPhone.
    public var connectedToPhone: Bool
    /// They are advertising that they accept a new phone.
    public var pairingMode: Bool

    static let defaultName = "Meta glasses"
}

/// What one scan knows: the glasses iOS holds a link to, and adverts heard recently.
struct NearbyList {
    /// An advert not heard again for this long drops out.
    static let forgetAfter: Duration = .seconds(12)

    private var held: [(id: UUID, name: String?)] = []
    private var heard: [UUID: (glasses: NearbyGlasses, at: ContinuousClock.Instant)] = [:]

    /// Meta's wristband can sit among the held peripherals too; only its name tells.
    mutating func update(held: [(id: UUID, name: String?)]) {
        self.held = held.filter { $0.name?.localizedCaseInsensitiveContains("band") != true }
    }

    mutating func hear(_ glasses: NearbyGlasses, at now: ContinuousClock.Instant = .now) {
        heard[glasses.id] = (glasses, now)
    }

    /// Held glasses (with what their adverts add), then the others heard, closest first.
    mutating func glasses(at now: ContinuousClock.Instant = .now) -> [NearbyGlasses] {
        heard = heard.filter { now - $0.value.at <= Self.forgetAfter }
        var list = held.map { pair -> NearbyGlasses in
            var glasses = NearbyGlasses(id: pair.id, name: pair.name ?? NearbyGlasses.defaultName, rssi: nil,
                                        connectedToPhone: true, pairingMode: false)
            if let advert = heard[pair.id]?.glasses {
                glasses.rssi = advert.rssi
                glasses.pairingMode = advert.pairingMode
                if glasses.name == NearbyGlasses.defaultName { glasses.name = advert.name }
            }
            return glasses
        }
        let heldIDs = Set(held.map(\.id))
        list += heard.values.map(\.glasses).filter { !heldIDs.contains($0.id) }
        return list.sorted { a, b in
            if a.connectedToPhone != b.connectedToPhone { return a.connectedToPhone }
            if a.pairingMode != b.pairingMode { return a.pairingMode }
            if a.rssi != b.rssi { return (a.rssi ?? -200) > (b.rssi ?? -200) }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
