import CoreBluetooth

/// What the glasses expose over Bluetooth LE.
enum MetaGatt {
    /// Meta's GATT service (0xFD5F). iOS lists glasses it holds a link to under it.
    static var service: CBUUID { CBUUID(string: "0000fd5f-0000-1000-8000-00805f9b34fb") }

    /// Holds the PSM of the glasses' L2CAP channel.
    static var psmCharacteristic: CBUUID { CBUUID(string: "05acbe9f-6f61-4ca9-80bf-c8bbb52991c0") }

    /// The PSM to open when the characteristic can't be read.
    static let defaultPSM: UInt16 = 0x80

    /// Meta's Bluetooth company id, the first two bytes (little-endian) of its manufacturer data.
    static let companyID: UInt16 = 0x01AB

    /// Meta's wristband advertises like the glasses but isn't a pair.
    static let bandProductID: UInt16 = 1537

    /// The PSM characteristic holds little-endian 16-bit words, e.g. `00 00 81 00`. The channel's PSM is the first
    /// word in the LE dynamic range (0x80–0xFF), else the first fixed one (0x01–0x7F).
    static func channelPSM(from value: [UInt8]) -> UInt16? {
        let words = stride(from: 0, to: value.count - 1, by: 2).map { UInt16(value[$0]) | UInt16(value[$0 + 1]) << 8 }
        return words.first { (0x80...0xFF).contains($0) } ?? words.first { (0x01...0x7F).contains($0) }
    }
}
