import CryptoKit
import Foundation

/// A wake word set: eight files for the English language feature (the wake word model and seven spoken prompts), with
/// the artifact id and version they are installed under. ReGlass ships no wake word files: a set comes from the
/// wearer's own files or a verified factory download, saved in Application Support (`WakeWordLibrary`). Every set is
/// made for one firmware build and goes only to glasses on that build. Two sets are pinned here as known-good
/// references from firmware 1082194281, with their sizes, SHA-256s and file UUIDs: Meta's factory set, and the custom
/// set the installer was proven with. A factory download for any build is checked against Meta's own data instead.
struct WakeWordSet: Sendable {
    struct Entry: Sendable, Equatable {
        let filename: String
        let size: Int
        let sha256: String
        let uuid: String
    }

    /// Where the set's files are. Nil for the pinned references, which have no files.
    let folder: URL?
    /// The glasses firmware build this set is made for (e.g. "1086324946"). It goes only to glasses running exactly
    /// that build: the wake engine and the resource versions belong to a firmware.
    let firmware: String
    let artifact: String
    /// The version as installed. A custom set adds a fresh suffix per install (see `deploymentVersion`).
    let baseVersion: String
    /// A fresh version per install: the MCU skips a file whose stored version matches the request.
    let freshVersionPerInstall: Bool
    /// In install order, the wake model last.
    let entries: [Entry]

    /// A custom wake model (its three primary thresholds set to the float just above 0.8) with the stock prompts:
    /// the custom set the installer was proven with. "Hey Meta" keeps working beside it.
    static let custom = WakeWordSet(
        folder: nil, firmware: verifiedFirmware,
        artifact: "glass-th08-26ff784e45441b5aa1e94", baseVersion: "glass08-26ff784e45", freshVersionPerInstall: true,
        entries: [
            Entry(filename: "BATTERY_LOW", size: 9670,
                  sha256: "73933597480b254286dd781fdae121686aaab751f7a62d23b8ba3654768477bd",
                  uuid: "6fb77cbb-bdfe-5b3d-bfc4-de41d3f95b1a"),
            Entry(filename: "BATTERY_LOW_SHUTDOWN", size: 8220,
                  sha256: "85f19d7e42c0b09ffd014b221c6b578b51ee26a6bcaf8ca62ac5360b3d958743",
                  uuid: "32001acc-d2e1-5c5c-9472-fd7083686586"),
            Entry(filename: "BLUETOOTH_NOT_CONNECTED", size: 11460,
                  sha256: "4209e8c3f05a01acfccefdff5445b3ac36ec2c721906d8e3445aaa8b16ad0950",
                  uuid: "7f7fa803-f6e7-528a-bb70-637da644777b"),
            Entry(filename: "DOWNLOADING_RESOURCES", size: 11895,
                  sha256: "5a1052d4b012fb1c4e471df72ccb12bf8257d252d01aaf411a3f1401db620624",
                  uuid: "6a418d70-35aa-5c4e-b70e-20c412514f6c"),
            Entry(filename: "OPEN_C50_APP", size: 12601,
                  sha256: "f77eccd7825648108c587b8f9a857d56eaddbae67960dd638f1d2ef445f6d365",
                  uuid: "b36bc1b4-7e8c-59c7-b769-c00c52985a87"),
            Entry(filename: "SETUP_ACTION_BUTTON", size: 18455,
                  sha256: "352e931685df9ce46de0dcfabe2a0d09fb5a9f7e731ef6b0647739a3c7e7713e",
                  uuid: "f6265b79-a2e1-53d8-b988-bd83b55eb50d"),
            Entry(filename: "THERMAL_HIGH_SHUTDOWN", size: 11157,
                  sha256: "85427df3d029caefd6444399d533fafb823fbc7d1d29bac79ee3b68daad16d78",
                  uuid: "70f8b913-546c-5652-8f98-e0556f13203a"),
            Entry(filename: "WAKE_WORD_MODEL", size: 698_792,
                  sha256: "26ff784e45441b5aa1e94cc802d785f2af2b6f8b16aa74a2e23be988dacd3ea9",
                  uuid: "176f7973-892c-5930-972b-b1da3a3fa103"),
        ])

    /// Meta's factory set: the stock wake model ("Hey Meta" only) and the same seven prompts, under Meta's own
    /// artifact id and version.
    static let heyMeta = WakeWordSet(
        folder: nil, firmware: verifiedFirmware,
        artifact: factoryArtifact, baseVersion: factoryVersion, freshVersionPerInstall: false,
        entries: [
            Entry(filename: "BATTERY_LOW", size: 9670,
                  sha256: "73933597480b254286dd781fdae121686aaab751f7a62d23b8ba3654768477bd",
                  uuid: "fba901ff-9d22-50a5-8490-7f7d5f095510"),
            Entry(filename: "BATTERY_LOW_SHUTDOWN", size: 8220,
                  sha256: "85f19d7e42c0b09ffd014b221c6b578b51ee26a6bcaf8ca62ac5360b3d958743",
                  uuid: "cadaeca4-1db7-5572-9b3b-4560ad3c55a7"),
            Entry(filename: "BLUETOOTH_NOT_CONNECTED", size: 11460,
                  sha256: "4209e8c3f05a01acfccefdff5445b3ac36ec2c721906d8e3445aaa8b16ad0950",
                  uuid: "bb83ff46-a6f7-5697-897a-ae602844dc06"),
            Entry(filename: "DOWNLOADING_RESOURCES", size: 11895,
                  sha256: "5a1052d4b012fb1c4e471df72ccb12bf8257d252d01aaf411a3f1401db620624",
                  uuid: "d7fc1039-c9e8-5075-b1d8-3c08c77b6c56"),
            Entry(filename: "OPEN_C50_APP", size: 12601,
                  sha256: "f77eccd7825648108c587b8f9a857d56eaddbae67960dd638f1d2ef445f6d365",
                  uuid: "0bdaf56a-3a93-5723-b70b-861e07b395df"),
            Entry(filename: "SETUP_ACTION_BUTTON", size: 18455,
                  sha256: "352e931685df9ce46de0dcfabe2a0d09fb5a9f7e731ef6b0647739a3c7e7713e",
                  uuid: "19c20a02-04f5-5458-82b0-edbad196dba0"),
            Entry(filename: "THERMAL_HIGH_SHUTDOWN", size: 11157,
                  sha256: "85427df3d029caefd6444399d533fafb823fbc7d1d29bac79ee3b68daad16d78",
                  uuid: "7b76ebf6-0eaf-5b9f-a36d-26dd3ab394d7"),
            Entry(filename: "WAKE_WORD_MODEL", size: 698_856,
                  sha256: "e12f58c8a90a2b90003fb845da47a4ee9c0cb9062d8fa6ee2b746eee7cbb1c4f",
                  uuid: "76c5f0ad-7ae9-536a-aac7-a2607e3c9498"),
        ])


    static let factoryArtifact = "967781345973994"
    /// The proven factory set's version: Meta's language resource version, then the language variant.
    static let factoryVersion = "1082207660.en_US.mai_03"
    /// The factory English variant the tested glasses carried before reset. Factory downloads select the same variant.
    static let factoryVariant = "en_US.mai_03"
    /// The firmware the two pinned references above (`heyMeta`, `custom`) were proven on.
    static let verifiedFirmware = "1082194281"
    /// Accepted SHA-256 fingerprints for the factory "Hey Meta" wake model. The model was byte-identical
    /// in both tested builds. A new model needs its fingerprint added here before it can be used.
    static let heyMetaModelFingerprints: Set<String> = [
        "e12f58c8a90a2b90003fb845da47a4ee9c0cb9062d8fa6ee2b746eee7cbb1c4f",
    ]

    /// Factory versions start with Meta's decimal resource version, followed by a dot and the factory variant.
    static func isFactoryVersion(_ version: String) -> Bool {
        let suffix = "." + factoryVariant
        guard version.hasSuffix(suffix) else { return false }
        let resource = version.dropLast(suffix.count)
        return (1...19).contains(resource.utf8.count) && resource.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// The file id the factory set uses for `filename` (Meta's ids, as the proven restore sent them).
    static func factoryUUID(for filename: String) -> String? {
        heyMeta.entries.first { $0.filename == filename }?.uuid
    }

    /// A factory set for glasses on `firmware`, from files ReGlass checked against Meta's own data: the seven prompts
    /// against the language pack's manifest, the wake model against `heyMetaModelFingerprints`. Nil when a file is
    /// missing or the model isn't Meta's "Hey Meta" model.
    static func factory(firmware: String, resourceVersion: String, contents: [String: [UInt8]]) -> WakeWordSet? {
        var entries: [Entry] = []
        for reference in heyMeta.entries {
            guard let bytes = contents[reference.filename] else { return nil }
            let sha = sha256(bytes)
            if reference.filename == ResourceOta.wakeModelFilename {
                guard heyMetaModelFingerprints.contains(sha), looksLikeWakeModel(bytes) else { return nil }
            }
            entries.append(Entry(filename: reference.filename, size: bytes.count, sha256: sha, uuid: reference.uuid))
        }
        return WakeWordSet(folder: nil, firmware: firmware, artifact: factoryArtifact,
                           baseVersion: resourceVersion + "." + factoryVariant, freshVersionPerInstall: false,
                           entries: entries)
    }
    /// The largest file a set may hold. The wake model is about 700 KB, each prompt under 20 KB.
    static let maxFileBytes = 2 * 1024 * 1024
    /// Every wake model this installer has sent begins with these four bytes ("XRSP").
    static let wakeModelMagic: [UInt8] = [0x58, 0x52, 0x53, 0x50]

    var totalBytes: Int { entries.reduce(ResourceOta.bootPlaceholderBytes.count) { $0 + $1.size } }

    /// The same set, with its files in `folder`.
    func at(_ folder: URL) -> WakeWordSet {
        WakeWordSet(folder: folder, firmware: firmware, artifact: artifact, baseVersion: baseVersion,
                    freshVersionPerInstall: freshVersionPerInstall, entries: entries)
    }

    // MARK: Loading

    /// A set read from its folder and checked, ready to send.
    struct Loaded: Sendable {
        let set: WakeWordSet
        let files: [ResourceOta.File]
        let contents: [[UInt8]]
    }

    /// Reads every file and checks its size and SHA-256 against the entries (which the import checked against the
    /// set's manifest, and a factory set against the pinned table). Nothing is sent from a set that fails.
    func load() throws -> Loaded {
        guard let folder else { throw WakeWordFault.damagedSet("no files") }
        var files: [ResourceOta.File] = [ResourceOta.bootPlaceholderFile]
        var contents: [[UInt8]] = [ResourceOta.bootPlaceholderBytes]
        for entry in entries {
            guard let uuid = Self.uuidBytes(entry.uuid) else { throw WakeWordFault.damagedSet("\(entry.filename) id") }
            let bytes: [UInt8]
            do { bytes = try Data(contentsOf: folder.appendingPathComponent(entry.filename)).byteArray } catch {
                throw WakeWordFault.damagedSet("\(entry.filename) unreadable")
            }
            guard bytes.count == entry.size, Self.sha256(bytes) == entry.sha256,
                  entry.filename != ResourceOta.wakeModelFilename || Self.looksLikeWakeModel(bytes) else {
                throw WakeWordFault.damagedSet(entry.filename)
            }
            files.append(ResourceOta.File(name: entry.filename, uuid: uuid))
            contents.append(bytes)
        }
        // Builds the request once, with the longest version this set can be installed under, so a set that could
        // never be sent is refused here.
        let longest = freshVersionPerInstall ? baseVersion + "-00000" : baseVersion
        _ = try ResourceOta.install(key: ResourceOta.Key(), artifact: artifact, version: longest, files: files)
        return Loaded(set: self, files: files, contents: contents)
    }

    /// The version for this install. A custom set: the base plus 5 fresh hex digits, different from what is installed.
    /// The factory set keeps Meta's version, as the restore it was built for did.
    func deploymentVersion(current: String?) throws -> String {
        guard freshVersionPerInstall else { return baseVersion }
        for _ in 0..<8 {
            let hex = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let version = baseVersion + "-" + hex.prefix(5)
            if version != current { return version }
        }
        throw WakeWordFault.malformed("no fresh version")
    }

    static func looksLikeWakeModel(_ bytes: [UInt8]) -> Bool {
        bytes.count > wakeModelMagic.count && Array(bytes.prefix(wakeModelMagic.count)) == wakeModelMagic
    }

    static func uuidBytes(_ text: String) -> [UInt8]? {
        guard UUID(uuidString: text) != nil else { return nil }
        let bytes = [UInt8](hexString: text.replacingOccurrences(of: "-", with: ""))
        return bytes?.count == 16 ? bytes : nil
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        Array(SHA256.hash(data: Data(bytes))).hexString
    }
}
