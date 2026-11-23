import Foundation

/// The resource-OTA conversation that replaces a language feature's files: svc28 starts and stops the glasses' OTA
/// application, and svc29 carries the install request, per-file statuses and feature activation. Wake word sets
/// were installed on Audio firmware 1082194281. Factory restore was also tested on 1086324946.
enum ResourceOta {
    /// The English language feature, which owns the wake word model and the seven spoken prompts.
    static let feature = "luna.language_en_us"
    static let languageType: Int64 = 1

    /// On cold boot, build 1082194281 looks up the capture override (type 6), wake word model (type 1), and
    /// render override (type 6) in that order. An absent tuning directory returns `-EINVAL` (-22) and stops
    /// the search. The placeholder creates the directory so missing overrides return `-ENOENT` (-2) and the
    /// glasses can load the wake word model.
    static let bootPlaceholderType: Int64 = 6
    static let bootPlaceholderFeature = "luna.audio_tunings"
    static let bootPlaceholderArtifact = "reglass-audio-tunings"
    static let bootPlaceholderVersion = "1.0.0"
    static let bootPlaceholderFilename = "BOOT_PLACEHOLDER"
    static let bootPlaceholderUUID: [UInt8] = [
        0xe5, 0xc3, 0x9c, 0x4a, 0x94, 0x50, 0x5e, 0x7e,
        0x9c, 0x2c, 0x51, 0x21, 0xd4, 0x6e, 0x18, 0x06,
    ]
    static let bootPlaceholderBytes: [UInt8] = [0x4f, 0x4b, 0x47, 0x4c]
    static let bootPlaceholderFile = File(
        name: bootPlaceholderFilename,
        uuid: bootPlaceholderUUID,
        type: bootPlaceholderType,
        feature: bootPlaceholderFeature,
        artifact: bootPlaceholderArtifact,
        version: bootPlaceholderVersion
    )

    /// The eight files of a complete set. The MCU replaces the whole feature directory when the set's identity
    /// changes, so an install always carries all eight.
    static let filenames: Set<String> = [
        "BATTERY_LOW", "BATTERY_LOW_SHUTDOWN", "BLUETOOTH_NOT_CONNECTED", "OPEN_C50_APP",
        "THERMAL_HIGH_SHUTDOWN", "SETUP_ACTION_BUTTON", "DOWNLOADING_RESOURCES", "WAKE_WORD_MODEL",
    ]
    static let wakeModelFilename = "WAKE_WORD_MODEL"

    /// One install's correlation ids, each a fresh lowercase UUID string. The glasses echo update (1) and
    /// attempt (3) in every reply; install (2) usually comes back absent.
    struct Key: Equatable, Sendable {
        let update: String
        let install: String
        let attempt: String

        init() {
            update = UUID().uuidString.lowercased()
            install = UUID().uuidString.lowercased()
            attempt = UUID().uuidString.lowercased()
        }

        var bytes: [UInt8] {
            Wire.fieldBytes(1, Array(update.utf8)) + Wire.fieldBytes(2, Array(install.utf8))
                + Wire.fieldBytes(3, Array(attempt.utf8))
        }
    }

    /// One row of the install request.
    struct File: Equatable, Sendable {
        let name: String
        let uuid: [UInt8]
        let type: Int64
        let feature: String
        let artifact: String?
        let version: String?

        init(name: String, uuid: [UInt8], type: Int64 = ResourceOta.languageType,
             feature: String = ResourceOta.feature, artifact: String? = nil, version: String? = nil) {
            self.name = name
            self.uuid = uuid
            self.type = type
            self.feature = feature
            self.artifact = artifact
            self.version = version
        }
    }

    enum Reply: Equatable {
        case fileStatus(uuid: [UInt8], status: Int64)
        case progress(stage: Int64)
        case rejected(error: Int64, stage: Int64, code: Int64)
        /// This MCU's completion is an empty type 7: no key, no success flag.
        case completion
        case featureResult(status: Int64, result: Int64)
    }

    // MARK: svc28, the OTA application

    /// Starts OTA app 1 with storage policy 5. The two entries at tag 3 select a resource update and identify
    /// the attempt. No firmware image is involved.
    static func startApplication(attempt: String) throws -> [UInt8] {
        guard UUID(uuidString: attempt) != nil, attempt.utf8.count == 36 else { throw invalid("attempt id") }
        let policy = Wire.fieldBytes(1, try Wire.fieldVarint(1, 5))
        return try Wire.fieldVarint(1, 1) + Wire.fieldBytes(2, policy)
            + Wire.fieldBytes(3, intent("ota_type", "resource"))
            + Wire.fieldBytes(3, intent("attempt_id", attempt))
    }

    static func stopApplication() -> [UInt8] { [0x08, 0x01] }

    /// An intent: key in field 1, the value in the bytes branch (field 5). Both are bytes.
    private static func intent(_ key: String, _ value: String) -> [UInt8] {
        Wire.fieldBytes(1, Array(key.utf8)) + Wire.fieldBytes(5, Array(value.utf8))
    }

    /// The app manager's result code (field 1). 1 is success; 11 on a stop means it had already stopped.
    static func applicationResult(_ payload: [UInt8]) throws -> Int64 {
        guard payload.count <= 4096 else { throw invalid("app-manager answer size") }
        let fields = try Wire.parse(payload)
        guard fields.has(1) else { throw invalid("app-manager answer without a result") }
        return fields.varint(1)
    }

    // MARK: svc29, install and enable

    /// The install request carries the key, the type 6 cold-boot placeholder row first, one row per language file
    /// `{1: type, 2: uuid, 3: version, 4: artifact, 6: feature, 7: filename}` (the wake model last), then field 9 = 1
    /// (resources only; not a force-reinstall flag). Never a firmware UUID, image offsets, URLs or key material.
    static func install(key: Key, artifact: String, version: String, files: [File]) throws -> [UInt8] {
        let languageFiles = Array(files.dropFirst())
        guard printable(artifact, max: 32), printable(version, max: 24),
              files.first == bootPlaceholderFile,
              languageFiles.count == filenames.count,
              languageFiles.allSatisfy({
                  $0.type == languageType && $0.feature == feature && $0.artifact == nil && $0.version == nil
              }),
              Set(languageFiles.map(\.name)) == filenames,
              files.last?.name == wakeModelFilename,
              files.allSatisfy({ $0.uuid.count == 16 }), Set(files.map(\.uuid)).count == files.count else {
            throw invalid("install request")
        }
        var bytes = Wire.fieldBytes(1, key.bytes)
        for file in files {
            let rowVersion = file.version ?? version
            let rowArtifact = file.artifact ?? artifact
            guard printable(rowArtifact, max: 32), printable(rowVersion, max: 24),
                  printable(file.feature, max: 24), printable(file.name, max: 24) else {
                throw invalid("install row")
            }
            let row = try Wire.fieldVarint(1, file.type) + Wire.fieldBytes(2, file.uuid)
                + Wire.fieldBytes(3, Array(rowVersion.utf8)) + Wire.fieldBytes(4, Array(rowArtifact.utf8))
                + Wire.fieldBytes(6, Array(file.feature.utf8)) + Wire.fieldBytes(7, Array(file.name.utf8))
            bytes += Wire.fieldBytes(8, row)
        }
        return bytes + (try Wire.fieldVarint(9, 1))
    }

    /// ENABLE (status 1) for the feature. Status 0 would be DISABLE, which is neither a query nor a restore.
    static func enable(key: Key) throws -> [UInt8] {
        let row = try Wire.fieldVarint(1, 1) + Wire.fieldBytes(2, Array(feature.utf8)) + Wire.fieldVarint(3, 1)
        return Wire.fieldBytes(1, key.bytes) + Wire.fieldBytes(2, row)
    }

    /// Reads one svc29 message. Nil for types that don't concern an install and for replies to another key; throws
    /// on a reply that can't be read.
    static func reply(type: Int, payload: [UInt8], key: Key) throws -> Reply? {
        let known = [ResourceOtaMessageType.progress, ResourceOtaMessageType.rejected,
                     ResourceOtaMessageType.fileStatus, ResourceOtaMessageType.completion,
                     ResourceOtaMessageType.featureStatusResponse]
        guard known.contains(type) else { return nil }
        if type == ResourceOtaMessageType.completion {
            guard payload.isEmpty else { throw invalid("completion with a body") }
            return .completion
        }
        let fields = try strictFields(payload)
        let echoed = try strictFields(fields.bytes(1))
        // The MCU fills key fields 1 and 3 and leaves out 2; check 2 only when it is there.
        guard echoed.repeatedBytes(1).count == 1, echoed.repeatedBytes(3).count == 1,
              echoed.bytes(1) == Array(key.update.utf8),
              !echoed.has(2) || echoed.bytes(2) == Array(key.install.utf8),
              echoed.bytes(3) == Array(key.attempt.utf8) else { return nil }
        switch type {
        case ResourceOtaMessageType.progress:
            return .progress(stage: fields.varint(2))
        case ResourceOtaMessageType.rejected:
            return .rejected(error: fields.varint(2), stage: fields.varint(3), code: fields.varint(5))
        case ResourceOtaMessageType.fileStatus:
            guard fields.bytes(3).count == 16 else { throw invalid("file status without a file id") }
            return .fileStatus(uuid: fields.bytes(3), status: fields.varint(2))
        case ResourceOtaMessageType.featureStatusResponse:
            let rows = fields.repeatedBytes(2)
            guard rows.count == 1 else { throw invalid("feature answer rows") }
            let row = try strictFields(rows[0])
            guard row.varint(1) == 1, row.bytes(2) == Array(feature.utf8) else { return nil }
            return .featureResult(status: row.varint(3), result: row.varint(4))
        default:
            return nil
        }
    }

    // MARK: Checks

    /// Printable ASCII without '/', non-empty, at most `max` bytes: what the MCU accepts in a path component.
    private static func printable(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= max && text.utf8.allSatisfy { $0 >= 32 && $0 < 127 && $0 != 47 }
    }

    /// A flat message whose spans are all complete, with each field number at most once. `Wire.parse` tolerates
    /// truncation on purpose; install replies must not.
    private static func strictFields(_ bytes: [UInt8]) throws -> Wire.Fields {
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
            at = tag.offset
            switch tag.value & 7 {
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
        .malformed("resource OTA: " + what)
    }
}
