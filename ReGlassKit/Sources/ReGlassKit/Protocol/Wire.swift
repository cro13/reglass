import Foundation

/// Bytes off the link that cannot be read as the format claims.
enum WireError: Error, Equatable {
    case truncatedVarint
    case negativeVarint(Int64)
    case fieldNumberOutOfRange(Int64)
    case unsupportedWireType(Int, field: Int)
}

/// Minimal protobuf-lite codec: enough to build and parse link-setup and service messages without a generated
/// stub. Byte layout matches the reference exactly, including its deliberate tolerance of truncated inputs.
enum Wire {

    // MARK: Encode

    /// A base-128 varint of a non-negative value.
    static func encodeVarint(_ value: Int64) throws -> [UInt8] {
        guard value >= 0 else { throw WireError.negativeVarint(value) }
        return encodeVarintUnsigned(value)
    }

    /// A varint whose bit pattern is read as unsigned, so a high bit set means 2^63 or more, not negative.
    static func encodeVarintUnsigned(_ value: Int64) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(10)
        var remaining = UInt64(bitPattern: value)
        while true {
            let b = UInt8(remaining & 0x7F)
            remaining >>= 7
            out.append(b | (remaining != 0 ? 0x80 : 0))
            if remaining == 0 { return out }
        }
    }

    static func fieldVarint(_ fieldNumber: Int, _ value: Int64) throws -> [UInt8] {
        tag(fieldNumber, 0) + (try encodeVarint(value))
    }

    /// As `fieldVarint`, but `value` is read as unsigned (u64 bitmasks and sequence bases).
    static func fieldVarintUnsigned(_ fieldNumber: Int, _ value: Int64) -> [UInt8] {
        tag(fieldNumber, 0) + encodeVarintUnsigned(value)
    }

    static func fieldBytes(_ fieldNumber: Int, _ value: [UInt8]) -> [UInt8] {
        tag(fieldNumber, 2) + encodeVarintUnsigned(Int64(value.count)) + value
    }

    // Field numbers are compile-time constants, so a negative one is a programming error, not bad input.
    private static func tag(_ fieldNumber: Int, _ wireType: Int) -> [UInt8] {
        precondition(fieldNumber >= 0, "field number must be non-negative")
        return encodeVarintUnsigned((Int64(fieldNumber) << 3) | Int64(wireType))
    }

    // MARK: Decode

    /// A parsed varint and the offset just past it.
    struct Varint: Equatable {
        let value: Int64
        let offset: Int
    }

    static func decodeVarint(_ data: [UInt8], _ offset: Int) throws -> Varint {
        var result: Int64 = 0
        var shift: Int64 = 0
        var at = offset
        while true {
            guard at < data.count else { throw WireError.truncatedVarint }
            let b = Int64(data[at])
            at += 1
            // The reference shifts a 64-bit value, whose shift count is taken mod 64; `&<<` does the same.
            result |= (b & 0x7F) &<< shift
            if b & 0x80 == 0 { return Varint(value: result, offset: at) }
            shift += 7
        }
    }

    /// One value read for a field.
    fileprivate enum Value {
        case varint(Int64)
        case bytes([UInt8])
    }

    /// A parsed flat message: field number → the values read for it, in wire order.
    struct Fields {
        private var byField: [Int: [(wireType: Int, value: Value)]] = [:]

        fileprivate mutating func add(_ fieldNumber: Int, _ wireType: Int, _ value: Value) {
            byField[fieldNumber, default: []].append((wireType, value))
        }

        /// The first length-delimited value for `field`, or `fallback`.
        func bytes(_ field: Int, _ fallback: [UInt8] = []) -> [UInt8] {
            for entry in byField[field] ?? [] {
                if entry.wireType == 2, case .bytes(let value) = entry.value { return value }
            }
            return fallback
        }

        /// The first varint value for `field`, or `fallback`.
        func varint(_ field: Int, _ fallback: Int64 = 0) -> Int64 {
            for entry in byField[field] ?? [] {
                if entry.wireType == 0, case .varint(let value) = entry.value { return value }
            }
            return fallback
        }

        func repeatedBytes(_ field: Int) -> [[UInt8]] {
            (byField[field] ?? []).compactMap { entry in
                if entry.wireType == 2, case .bytes(let value) = entry.value { return value }
                return nil
            }
        }

        func has(_ field: Int) -> Bool { byField[field] != nil }
    }

    static func parse(_ data: [UInt8]) throws -> Fields {
        var fields = Fields()
        var offset = 0
        let n = data.count
        while offset < n {
            let key = try decodeVarint(data, offset)
            offset = key.offset
            let fieldNumberLong = Int64(bitPattern: UInt64(bitPattern: key.value) >> 3)
            guard fieldNumberLong <= Int64(Int32.max) else {
                throw WireError.fieldNumberOutOfRange(fieldNumberLong)
            }
            let fieldNumber = Int(fieldNumberLong)
            switch Int(key.value & 0x07) {
            case 0:
                let value = try decodeVarint(data, offset)
                offset = value.offset
                fields.add(fieldNumber, 0, .varint(value.value))
            case 2:
                let length = try decodeVarint(data, offset)
                offset = length.offset
                // The reference slices with an arbitrary-precision length: one past the end yields the
                // bytes that are there and leaves the cursor past the end, so the loop stops.
                let remaining = Int64(n - offset)
                let fits = length.value >= 0 && length.value <= remaining
                let take = fits ? Int(length.value) : Int(remaining)
                fields.add(fieldNumber, 2, .bytes(Array(data[offset..<(offset + take)])))
                offset = fits ? offset + take : n
            case 5:
                offset += 4   // fixed32
            case 1:
                offset += 8   // fixed64
            default:
                throw WireError.unsupportedWireType(Int(key.value & 0x07), field: fieldNumber)
            }
        }
        return fields
    }
}
