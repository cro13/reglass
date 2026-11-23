import Foundation

/// Firmware OTA messages for the Audio (orca) glasses. svc28 starts the OTA application, svc29 carries the install
/// request and status replies, and svc20 transfers the image over Airship. The request adds the image UUID,
/// payload offset, headers and key-encryption-key material to the fields used by resource installs.
enum FirmwareOta {
    /// Device type and firmware version to report when requesting a full-image offer.
    static let deviceType = "ota.orca.user"
    static let queryFirmwareVersion = "0"

    /// svc28 starts the same OTA application for firmware and resources, with different update types and storage
    /// policies.
    static let applicationId: Int64 = 1

    /// One file's status as reported by the glasses on svc29.
    enum FileStatus: Int64, Equatable, Sendable {
        case unknown = 0
        /// Already present on the device: skip it.
        case have = 1
        /// The phone must push this file over Airship.
        case send = 2
        /// The phone must push it, once the device is ready.
        case waiting = 3
    }

    /// The stages reported in svc29 progress replies. Transfer, download and startup are informational.
    /// Apply, reboot and complete are expected only after the full image has been authorized.
    enum Stage {
        static let unknown: Int64 = 0
        static let transfer: Int64 = 1
        static let apply: Int64 = 2
        static let reboot: Int64 = 3
        static let stopped: Int64 = 4
        static let startup: Int64 = 5
        static let complete: Int64 = 6
        static let download: Int64 = 7
    }

    /// A firmware reply on svc29. `OtaUpdateInstallError` carries key (1), stage (2), a uint32 errorCode (3),
    /// retryable (4), an error enum (5), an optional errorData enum (6) and otaType (7). Progress percentage
    /// in `OtaUpdateInstallProgress` is a little-endian fixed64 double in field 3.
    enum Reply: Equatable, Sendable {
        case fileStatus(uuid: [UInt8], status: FileStatus)
        case progress(stage: Int64, percent: Double?)
        case error(Failure)
    }

    /// An `OtaUpdateInstallError`, field by field.
    struct Failure: Equatable, Sendable, CustomStringConvertible {
        let code: Int64
        let retryable: Bool
        let stage: Int64
        let errorEnum: Int64
        /// The `errorData` oneof (field 6) enum value, when the device sent one.
        let detail: Int64?

        var description: String {
            "code \(code), enum \(errorEnum), stage \(stage), \(retryable ? "retryable" : "not retryable")"
                + (detail.map { ", detail \($0)" } ?? "")
        }
    }

    // MARK: svc28 — starting the OTA application (firmware)

    /// Starts OTA app 1 on svc28. The storage policy at tag 2 reserves space in MB for the image plus headroom.
    /// The two entries at tag 3 select a firmware update and identify the attempt.
    static func startApplication(attempt: String, requiredSpaceMB: Int64) throws -> [UInt8] {
        guard UUID(uuidString: attempt) != nil, attempt.utf8.count == 36 else { throw invalid("attempt id") }
        guard requiredSpaceMB > 0, requiredSpaceMB <= 4096 else { throw invalid("required space") }
        // The required storage in MB is under tag 1 → tag 1 inside the policy at tag 2.
        let policy = Wire.fieldBytes(1, try Wire.fieldVarint(1, requiredSpaceMB))
        return try Wire.fieldVarint(1, applicationId) + Wire.fieldBytes(2, policy)
            + Wire.fieldBytes(3, intent("ota_type", "firmware"))
            + Wire.fieldBytes(3, intent("attempt_id", attempt))
    }

    /// Rounds the image size up to MiB, adds headroom and clamps the result to the start request's range.
    static func requiredSpaceMB(totalBytes: Int, headroomMB: Int64 = 16) -> Int64 {
        let mib = (Int64(max(0, totalBytes)) + (1024 * 1024 - 1)) / (1024 * 1024)
        return min(4096, max(1, mib + max(0, headroomMB)))
    }

    /// Firmware and resource installs use the same OTA application stop request.
    static func stopApplication() -> [UInt8] { ResourceOta.stopApplication() }

    /// Firmware and resource starts both send an intent as key bytes at tag 1 and value bytes at tag 5.
    private static func intent(_ key: String, _ value: String) -> [UInt8] {
        Wire.fieldBytes(1, Array(key.utf8)) + Wire.fieldBytes(5, Array(value.utf8))
    }

    /// The app-manager result (field 1): 1 is success, 11 on a stop means it had already stopped. Shared with the
    /// resource path.
    static func applicationResult(_ payload: [UInt8]) throws -> Int64 {
        try ResourceOta.applicationResult(payload)
    }

    // MARK: svc29 firmware install request (message 1)

    /// Requests installation of a single image delivered over Airship on the companion link. The Audio glasses
    /// pull the image from the phone.
    ///
    /// The request omits the list of additional packs (tag 8), sets the resources-only flag (tag 9) to 0,
    /// and sends an empty download URL (tag 10).
    static func install(key: ResourceOta.Key, offer: FirmwareOffer, fileUuid: [UInt8]) throws -> [UInt8] {
        guard fileUuid.count == 16 else { throw invalid("primary file id") }
        guard offer.fileSize > 0, offer.fileSize <= FirmwareOffer.maxImageBytes else { throw invalid("file size") }
        guard printableOrEmpty(offer.targetVersion, max: 64), printableOrEmpty(offer.baseVersion, max: 64),
              offer.metaHeaders.utf8.count <= 16_384,
              offer.releaseChannelId.utf8.count <= 128,
              (offer.kekHash ?? "").utf8.count <= 256 else {
            throw invalid("install field")
        }
        // The payload must be a real, non-empty span inside the file we send whole: offset in [0, fileSize) and
        // offset + payloadSize <= fileSize. (`FirmwareOffer` already enforces this; re-asserted at the wire.) The
        // whole downloaded file is still transferred verbatim — offset/size only tell the device where the image is.
        guard offer.payloadOffset >= 0, offer.payloadOffset < Int64(offer.fileSize), offer.payloadSize > 0,
              Int64(offer.payloadSize) <= Int64(offer.fileSize) - offer.payloadOffset else {
            throw invalid("payload offset/size")
        }

        var bytes = Wire.fieldBytes(1, key.bytes)
        bytes += Wire.fieldBytes(2, fileUuid)
        if !offer.baseVersion.isEmpty { bytes += Wire.fieldBytes(3, Array(offer.baseVersion.utf8)) }
        bytes += Wire.fieldBytes(4, Array(offer.targetVersion.utf8))
        bytes += try Wire.fieldVarint(5, Int64(offer.payloadSize))
        bytes += try Wire.fieldVarint(6, offer.payloadOffset)
        bytes += Wire.fieldBytes(7, Array(offer.metaHeaders.utf8))
        bytes += try Wire.fieldVarint(9, 0)
        bytes += Wire.fieldBytes(10, [])
        if let kekId = offer.kekId { bytes += try Wire.fieldVarint(11, kekId) }
        if let kekHash = offer.kekHash, !kekHash.isEmpty { bytes += Wire.fieldBytes(12, Array(kekHash.utf8)) }
        if !offer.releaseChannelId.isEmpty {
            bytes += Wire.fieldBytes(14, Array(offer.releaseChannelId.utf8))
        }
        return bytes
    }

    // Message 8 enables additional resources using their selected identities and a key containing only the
    // install session ID. A single-image install skips that message.

    // MARK: svc29 — reading the device's replies

    /// Reads file status, progress or errors on svc29 for this install. The glasses echo update (1) and
    /// attempt (3), and usually omit install (2). Returns nil for unrelated messages and throws on malformed replies.
    static func reply(type: Int, payload: [UInt8], key: ResourceOta.Key) throws -> Reply? {
        let known = [ResourceOtaMessageType.progress, ResourceOtaMessageType.rejected,
                     ResourceOtaMessageType.fileStatus]
        guard known.contains(type) else { return nil }
        // Enforce the wire type of every field we read, so a length-delimited span where a varint is expected is
        // rejected (and never silently read back as 0). `strictFields` throws on a mismatch for any named field.
        let fields: Wire.Fields
        switch type {
        case ResourceOtaMessageType.fileStatus:                                     // OtaUpdateFileStatus (type 4)
            fields = try strictFields(payload, lengthDelimited: [1, 3], varints: [2, 4])
        case ResourceOtaMessageType.progress:                                       // OtaUpdateInstallProgress (type 2)
            fields = try strictFields(payload, lengthDelimited: [1, 4], varints: [2, 5], fixed64: [3])
        case ResourceOtaMessageType.rejected:                                       // OtaUpdateInstallError (type 3)
            fields = try strictFields(payload, lengthDelimited: [1], varints: [2, 3, 4, 5, 6, 7])
        default:
            return nil
        }
        let echoed = try strictFields(fields.bytes(1), lengthDelimited: [1, 2, 3])
        guard echoed.repeatedBytes(1).count == 1, echoed.repeatedBytes(3).count == 1,
              echoed.bytes(1) == Array(key.update.utf8),
              !echoed.has(2) || echoed.bytes(2) == Array(key.install.utf8),
              echoed.bytes(3) == Array(key.attempt.utf8) else { return nil }
        switch type {
        case ResourceOtaMessageType.fileStatus:                                     // OtaUpdateFileStatus (type 4)
            guard fields.bytes(3).count == 16 else { throw invalid("file status without a file id") }
            let status = FileStatus(rawValue: fields.varint(2)) ?? .unknown
            return .fileStatus(uuid: fields.bytes(3), status: status)
        case ResourceOtaMessageType.progress:                                       // OtaUpdateInstallProgress (type 2)
            // Read the little-endian fixed64 progressPercentage (field 3) separately because `Wire.parse` skips it.
            return .progress(stage: fields.varint(2), percent: fixed64Double(payload, field: 3))
        case ResourceOtaMessageType.rejected:                                       // OtaUpdateInstallError (type 3)
            // Keep errorCode (3), error (5) and errorData (6) separate so a refusal retains its numeric details.
            return .error(Failure(code: fields.varint(3), retryable: fields.varint(4) != 0, stage: fields.varint(2),
                                  errorEnum: fields.varint(5), detail: fields.has(6) ? fields.varint(6) : nil))
        default:
            return nil
        }
    }

    /// Reads the little-endian fixed64 double for `wanted` from a flat message. `Wire.parse` skips fixed64 fields
    /// (it advances the cursor but keeps no value), so this walks the top-level fields itself. Nil when the field is
    /// absent or has a different wire type. Used for `OtaUpdateInstallProgress.progressPercentage` (field 3).
    static func fixed64Double(_ bytes: [UInt8], field wanted: Int) -> Double? {
        var at = 0
        while at < bytes.count {
            guard let tag = try? Wire.decodeVarint(bytes, at) else { return nil }
            at = tag.offset
            let field = Int(tag.value >> 3)
            switch tag.value & 7 {
            case 0:
                guard let next = try? Wire.decodeVarint(bytes, at) else { return nil }
                at = next.offset
            case 1:
                guard bytes.count - at >= 8 else { return nil }
                if field == wanted {
                    var raw: UInt64 = 0
                    for index in 0..<8 { raw |= UInt64(bytes[at + index]) << (8 * index) }
                    return Double(bitPattern: raw)
                }
                at += 8
            case 2:
                guard let length = try? Wire.decodeVarint(bytes, at), length.value >= 0,
                      length.value <= Int64(bytes.count - length.offset) else { return nil }
                at = length.offset + Int(length.value)
            case 5:
                guard bytes.count - at >= 4 else { return nil }
                at += 4
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: Checks

    /// Printable ASCII (no '/'), possibly empty, at most `max` bytes: a version string the MCU accepts.
    private static func printableOrEmpty(_ text: String, max: Int) -> Bool {
        text.utf8.count <= max && text.utf8.allSatisfy { $0 >= 32 && $0 < 127 && $0 != 47 }
    }

    /// A flat message whose spans are all complete, each field number at most once — install replies must not be
    /// truncated (the same discipline `ResourceOta` applies to its replies). Any field listed in `lengthDelimited`,
    /// `varints` or `fixed64` must carry that exact wire type, so a mistyped field is rejected rather than misread.
    private static func strictFields(_ bytes: [UInt8], lengthDelimited: Set<Int> = [], varints: Set<Int> = [],
                                     fixed64: Set<Int> = []) throws -> Wire.Fields {
        guard bytes.count <= 16_384 else { throw invalid("oversized reply") }
        var at = 0, count = 0
        var seen = Set<Int64>()
        while at < bytes.count {
            count += 1
            guard count <= 256 else { throw invalid("too many fields") }
            let tag = try Wire.decodeVarint(bytes, at)
            guard tag.value > 0, tag.value >> 3 > 0, seen.insert(tag.value >> 3).inserted else {
                throw invalid("repeated or empty field")
            }
            let field = Int(tag.value >> 3), kind = tag.value & 7
            if varints.contains(field), kind != 0 { throw invalid("field \(field) must be a varint") }
            if fixed64.contains(field), kind != 1 { throw invalid("field \(field) must be fixed64") }
            if lengthDelimited.contains(field), kind != 2 { throw invalid("field \(field) must be length-delimited") }
            at = tag.offset
            switch kind {
            case 0:
                at = try Wire.decodeVarint(bytes, at).offset
            case 1:
                guard bytes.count - at >= 8 else { throw invalid("truncated reply") }
                at += 8
            case 2:
                let size = try Wire.decodeVarint(bytes, at)
                guard size.value >= 0, size.value <= Int64(bytes.count - size.offset) else {
                    throw invalid("truncated reply")
                }
                at = size.offset + Int(size.value)
            case 5:
                guard bytes.count - at >= 4 else { throw invalid("truncated reply") }
                at += 4
            default:
                throw invalid("unknown wire type")
            }
        }
        return try Wire.parse(bytes)
    }

    private static func invalid(_ what: String) -> WakeWordFault {
        .malformed("firmware OTA: " + what)
    }
}
