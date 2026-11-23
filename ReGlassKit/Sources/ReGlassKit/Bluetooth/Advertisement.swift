import CoreBluetooth
import Foundation

/// One advert the scan heard, reduced to what finding glasses needs.
struct Advertisement: Sendable {
    let id: UUID
    /// The advertised local name, else the name iOS has cached for the peripheral.
    let name: String?
    /// Nil when iOS reports 127 (not available).
    let rssi: Int?
    /// The whole manufacturer data field, company id first.
    let manufacturerData: [UInt8]?
    let advertisesMetaService: Bool

    init(peripheral: CBPeripheral, data: [String: Any], rssi: Int) {
        id = peripheral.identifier
        name = data[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        self.rssi = rssi == 127 ? nil : rssi
        manufacturerData = (data[CBAdvertisementDataManufacturerDataKey] as? Data)?.byteArray
        let services = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        advertisesMetaService = services.contains(MetaGatt.service)
    }

    /// The manufacturer data after Meta's company id, or nil when the advert carries none of Meta's.
    var metaData: [UInt8]? {
        guard let data = manufacturerData, data.count >= 2,
              UInt16(data[0]) | UInt16(data[1]) << 8 == MetaGatt.companyID else { return nil }
        return Array(data[2...])
    }

    /// The glasses this advert is from, or nil when it isn't a Meta advert or is Meta's wristband.
    var glasses: NearbyGlasses? {
        let meta = metaData
        guard meta != nil || advertisesMetaService else { return nil }
        let advert = meta.flatMap(MetaAdvert.init)
        if advert?.productID == MetaGatt.bandProductID { return nil }
        return NearbyGlasses(id: id, name: name ?? MetaAdvert.productName(advert?.productID), rssi: rssi,
                             connectedToPhone: false, pairingMode: advert?.pairingMode == true)
    }
}

/// What Meta's manufacturer data says: which product, and whether it takes a new phone.
struct MetaAdvert: Equatable {
    let productID: UInt16
    let pairingMode: Bool

    /// `data` follows the company id: legacy `[product:2 LE][flags]`, or V2 (first byte ≥ 0x80)
    /// `[version][product:2 LE][reserved][flags]`. Bit 0 of the flags is pairing mode.
    init?(_ data: [UInt8]) {
        guard data.count >= 3 else { return nil }
        if data[0] >= 0x80 {
            productID = UInt16(data[1]) | UInt16(data[2]) << 8
            pairingMode = data.count >= 5 && data[4] & 1 != 0
        } else {
            productID = UInt16(data[0]) | UInt16(data[1]) << 8
            pairingMode = data[2] & 1 != 0
        }
    }

    static func productName(_ productID: UInt16?) -> String {
        switch productID {
        case 257: return "Ray-Ban Stories"
        case 259: return "Meta Ray-Ban Display"
        case 264: return "Oakley Meta Vanguard"
        case 265: return "Oakley Meta HSTN"
        default: return NearbyGlasses.defaultName
        }
    }
}
