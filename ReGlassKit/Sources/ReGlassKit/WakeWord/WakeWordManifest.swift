import Foundation

/// `manifest.json`: what a wake word set is, next to its eight files (docs/WAKE-WORD.md has it with an example):
///
///     { "schema": 1, "format": "reglass-wake-word-set", "role": "custom" | "factory", "name": "…",
///       "firmware": "1082194281", "feature": "…", "artifactId": "…", "version": "…",
///       "entries": [ { "filename": "…", "size": 0, "sha256": "…", "uuid": "…" }, … ] }
///
/// The earlier "wearwolf-wake-word-set" format is also accepted with the same checks.
/// Extra keys are ignored. ReGlass writes its own copy in the current format.
struct WakeWordManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var filename: String
        var size: Int
        var sha256: String
        var uuid: String
    }

    var schema: Int
    var format: String
    var role: String
    var name: String?
    var firmware: String
    var feature: String
    var artifactId: String
    var version: String
    var entries: [Entry]
    /// Written by ReGlass when it keeps a copy.
    var addedAt: Date?

    static let format = "reglass-wake-word-set"
    /// The pre-release project name. Import it with the same checks, then write the current format.
    static let previousFormat = "wearwolf-wake-word-set"
    static let filename = "manifest.json"
    static let maxBytes = 64 * 1024
    /// A custom set's version gets "-xxxxx" per install and the glasses take at most 24 bytes.
    static let maxCustomVersionBytes = 18
    static let maxNameLength = 40

    /// The set the manifest describes, checked, and which slot it fills. `ReGlassError.wakeWordSetInvalid` names
    /// the first thing wrong, in plain words.
    struct Checked {
        let wakeWord: WakeWord
        let name: String
        let set: WakeWordSet
    }

    static func decode(_ data: [UInt8]) throws -> WakeWordManifest {
        guard data.count <= maxBytes else { throw invalid("Its manifest is too large.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(WakeWordManifest.self, from: Data(data))
        } catch {
            throw invalid("Its manifest.json can't be read.")
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    func checked() throws -> Checked {
        guard schema == 1 else { throw Self.invalid("Its manifest has a schema ReGlass doesn't know.") }
        let wakeWord: WakeWord
        switch format {
        case Self.format, Self.previousFormat:
            switch role {
            case "factory": wakeWord = .heyMeta
            case "custom": wakeWord = .custom
            default: throw Self.invalid("Its manifest's role must be \u{201C}custom\u{201D} or \u{201C}factory\u{201D}.")
            }
        default:
            throw Self.invalid("Its manifest isn't a ReGlass wake word set.")
        }
        // The set says which firmware build it is made for; the installer sends it only to glasses on that build.
        guard (1...19).contains(firmware.utf8.count), firmware.utf8.allSatisfy({ (48...57).contains($0) }),
              firmware != "0" else {
            throw Self.invalid("Its manifest doesn't say which firmware it's made for.")
        }
        guard feature == ResourceOta.feature else { throw Self.invalid("It's for a feature other than the English wake word.") }

        let listed = try Self.checkedEntries(entries)
        switch wakeWord {
        case .heyMeta:
            // A factory set is Meta's own: Meta's artifact and a factory language version, Meta's file ids, and
            // Meta's "Hey Meta" model (by fingerprint). The proven version must also have the proven prompts; a
            // newer version's prompts were checked against Meta's language manifest when ReGlass downloaded them.
            guard artifactId == WakeWordSet.factoryArtifact, WakeWordSet.isFactoryVersion(version),
                  listed.allSatisfy({ WakeWordSet.factoryUUID(for: $0.filename) == $0.uuid }),
                  let model = listed.first(where: { $0.filename == ResourceOta.wakeModelFilename }),
                  WakeWordSet.heyMetaModelFingerprints.contains(model.sha256),
                  version != WakeWordSet.factoryVersion || listed == WakeWordSet.heyMeta.entries else {
                throw Self.invalid("It isn't Meta's factory set: its files or ids differ.")
            }
            let set = WakeWordSet(folder: nil, firmware: firmware, artifact: artifactId, baseVersion: version,
                                  freshVersionPerInstall: false, entries: listed)
            return Checked(wakeWord: .heyMeta, name: "Hey Meta", set: set)
        case .custom:
            guard Self.isPathSafe(artifactId, max: 32) else { throw Self.invalid("Its artifact id can't be used.") }
            guard artifactId != WakeWordSet.factoryArtifact, artifactId != ResourceOta.bootPlaceholderArtifact else {
                throw Self.invalid("Its artifact id is taken by the glasses' own files. Choose another one.")
            }
            guard Self.isPathSafe(version, max: Self.maxCustomVersionBytes) else {
                throw Self.invalid("Its version can't be used: at most \(Self.maxCustomVersionBytes) letters, digits or dashes.")
            }
            let ids = Set(listed.map(\.uuid))
            guard !ids.contains(where: { Self.uuidHex($0) == ResourceOta.bootPlaceholderUUID.hexString }),
                  ids.isDisjoint(with: WakeWordSet.heyMeta.entries.map(\.uuid)) else {
                throw Self.invalid("Its file ids are taken by the factory set. Give each file a new id.")
            }
            let proven = WakeWordSet.custom
            if artifactId == proven.artifact, version != proven.baseVersion || listed != proven.entries {
                throw Self.invalid("It reuses the artifact id of another set, with different files.")
            }
            let name = Self.displayName(name)
            let set = WakeWordSet(folder: nil, firmware: firmware, artifact: artifactId, baseVersion: version,
                                  freshVersionPerInstall: true, entries: listed)
            return Checked(wakeWord: .custom, name: name, set: set)
        }
    }

    /// Exactly the eight files, each once, sizes in range, lowercase SHA-256 and UUIDs (each id once), in install
    /// order: the seven prompts by name, then the wake model.
    private static func checkedEntries(_ entries: [Entry]) throws -> [WakeWordSet.Entry] {
        guard entries.count == ResourceOta.filenames.count else {
            throw invalid("Its manifest must list exactly the eight files.")
        }
        var seen = Set<String>(), ids = Set<String>()
        var total = 0
        var listed: [WakeWordSet.Entry] = []
        for entry in entries {
            guard ResourceOta.filenames.contains(entry.filename) else {
                throw invalid("Its manifest lists \(shown(entry.filename)), which isn't one of the eight files.")
            }
            guard seen.insert(entry.filename).inserted else { throw invalid("Its manifest lists \(entry.filename) twice.") }
            guard (1...WakeWordSet.maxFileBytes).contains(entry.size) else {
                throw invalid("\(entry.filename) has a size ReGlass won't send.")
            }
            total += entry.size
            let sha = entry.sha256.lowercased()
            guard sha.utf8.count == 64, sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw invalid("\(entry.filename) has no valid SHA-256 in the manifest.")
            }
            let uuid = entry.uuid.lowercased()
            guard WakeWordSet.uuidBytes(uuid) != nil, uuid.utf8.count == 36 else {
                throw invalid("\(entry.filename) has no valid uuid in the manifest.")
            }
            guard ids.insert(uuid).inserted else { throw invalid("Two files share the id of \(entry.filename).") }
            listed.append(WakeWordSet.Entry(filename: entry.filename, size: entry.size, sha256: sha, uuid: uuid))
        }
        guard total <= 4 * 1024 * 1024 else { throw invalid("It's larger than any set ReGlass sends.") }
        return listed.sorted { a, b in
            if a.filename == ResourceOta.wakeModelFilename { return false }
            if b.filename == ResourceOta.wakeModelFilename { return true }
            return a.filename < b.filename
        }
    }

    /// ReGlass's own copy of a checked set.
    static func stored(_ checked: Checked, addedAt: Date) -> WakeWordManifest {
        WakeWordManifest(
            schema: 1, format: format, role: checked.wakeWord == .heyMeta ? "factory" : "custom",
            name: checked.wakeWord == .custom ? checked.name : nil,
            firmware: checked.set.firmware, feature: ResourceOta.feature,
            artifactId: checked.set.artifact, version: checked.set.baseVersion,
            entries: checked.set.entries.map {
                Entry(filename: $0.filename, size: $0.size, sha256: $0.sha256, uuid: $0.uuid)
            },
            addedAt: addedAt)
    }

    /// Printable ASCII without '/', non-empty, at most `max` bytes: what the glasses accept in a path component.
    private static func isPathSafe(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= max && text.utf8.allSatisfy { $0 > 32 && $0 < 127 && $0 != 47 }
    }

    private static func displayName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return "Custom wake word" }
        return String(trimmed.prefix(maxNameLength))
    }

    private static func uuidHex(_ uuid: String) -> String {
        uuid.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// A value from the file, cut short and printable, for a message.
    private static func shown(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 })
        return "\u{201C}" + (clean.count > 32 ? String(clean.prefix(32)) + "…" : clean) + "\u{201D}"
    }

    static func invalid(_ reason: String) -> ReGlassError {
        .wakeWordSetInvalid(reason)
    }
}
