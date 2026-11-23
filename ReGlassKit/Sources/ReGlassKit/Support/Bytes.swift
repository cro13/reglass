import Foundation

// ReGlassKit works in `[UInt8]` and converts to `Data` only at Apple API edges (CoreBluetooth, CryptoKit,
// URLSession, files). A `Data` slice keeps its parent's indices, which is an easy way to read the wrong byte.

extension Array where Element == UInt8 {
    /// Lowercase hex, no separators.
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses lowercase or uppercase hex with no separators; nil for anything else.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        self = out
    }
}

extension Data {
    /// A fresh, zero-indexed copy of the bytes.
    var byteArray: [UInt8] { [UInt8](self) }
}

/// Compares two byte strings without stopping at the first difference.
func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<a.count { difference |= a[i] ^ b[i] }
    return difference == 0
}

/// Cryptographically secure random bytes.
func secureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes
}
