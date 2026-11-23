import Foundation

/// The installed language resources, as listed in svc22's DeviceInfoResponse: artifacts in field 14
/// `{1: id, 2: version, 3: type}`, features in field 16 `{1: name, 2: status}`. Only these two lists are kept; the
/// response's serial, account and time fields are never read. The two lists are not paired by position.
struct ResourceInventory: Equatable, Sendable {
    struct Artifact: Equatable, Sendable {
        let id: String?
        let version: String?
        let type: String?
    }

    struct Feature: Equatable, Sendable {
        let name: String?
        /// 1 is enabled. Nil when the glasses left it out, which an interrupted install can cause.
        let status: Int64?
    }

    let artifacts: [Artifact]
    let features: [Feature]

    static func decode(_ payload: [UInt8]) throws -> ResourceInventory {
        guard payload.count <= 256 * 1024 else { throw invalid() }
        let root = try checked(payload, bytes: [14, 16])
        let rawArtifacts = root.repeatedBytes(14)
        let rawFeatures = root.repeatedBytes(16)
        guard rawArtifacts.count <= 256, rawFeatures.count <= 256 else { throw invalid() }
        let artifacts = try rawArtifacts.map { bytes -> Artifact in
            let row = try checked(bytes, bytes: [1, 2, 3])
            return Artifact(id: try text(row, 1), version: try text(row, 2), type: try text(row, 3))
        }
        let features = try rawFeatures.map { bytes -> Feature in
            let row = try checked(bytes, bytes: [1], varints: [2])
            return Feature(name: try text(row, 1), status: row.has(2) ? row.varint(2) : nil)
        }
        return ResourceInventory(artifacts: artifacts, features: features)
    }

    /// One UTF-8 value without control characters, at most 256 bytes; nil when the field is absent.
    private static func text(_ fields: Wire.Fields, _ field: Int) throws -> String? {
        guard fields.has(field) else { return nil }
        let values = fields.repeatedBytes(field)
        guard values.count == 1, let bytes = values.first, bytes.count <= 256,
              let value = String(bytes: bytes, encoding: .utf8),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid()
        }
        return value
    }

    /// `Wire.parse` tolerates truncation; the inventory requires every span complete, the named fields in their
    /// expected wire types, and each varint field at most once.
    private static func checked(_ data: [UInt8], bytes: Set<Int>, varints: Set<Int> = []) throws -> Wire.Fields {
        var offset = 0, count = 0
        var seenVarints = Set<Int>()
        while offset < data.count {
            count += 1
            guard count <= 4096 else { throw invalid() }
            let tag = try Wire.decodeVarint(data, offset)
            offset = tag.offset
            guard tag.value > 0 else { throw invalid() }
            let field = Int(tag.value >> 3), kind = Int(tag.value & 7)
            guard field > 0 else { throw invalid() }
            if bytes.contains(field), kind != 2 { throw invalid() }
            if varints.contains(field), kind != 0 { throw invalid() }
            if varints.contains(field), !seenVarints.insert(field).inserted { throw invalid() }
            switch kind {
            case 0:
                offset = try Wire.decodeVarint(data, offset).offset
            case 1:
                guard data.count - offset >= 8 else { throw invalid() }
                offset += 8
            case 2:
                let length = try Wire.decodeVarint(data, offset)
                offset = length.offset
                guard length.value >= 0, length.value <= Int64(data.count - offset) else { throw invalid() }
                offset += Int(length.value)
            case 5:
                guard data.count - offset >= 4 else { throw invalid() }
                offset += 4
            default:
                throw invalid()
            }
        }
        return try Wire.parse(data)
    }

    private static func invalid() -> WakeWordFault {
        .malformed("the resource list could not be read")
    }
}
