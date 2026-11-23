import Foundation

/// The wake words the installer knows, from an imported set or a verified factory download (see `WakeWordLibrary`).
public enum WakeWord: String, CaseIterable, Sendable, Equatable {
    /// Meta's factory wake word, restored from an imported or downloaded factory set.
    case heyMeta
    /// A custom wake word, from a custom set the wearer imported.
    case custom

    /// How the log names the choice.
    var logName: String { self == .custom ? "custom" : "factory" }
}

/// What the glasses report having installed.
public enum InstalledWakeWord: Sendable, Equatable {
    /// Meta's factory set, enabled.
    case heyMeta
    /// A custom set ReGlass knows (imported now, installed by ReGlass before, or the proven one), enabled, under
    /// its artifact id.
    case custom(artifact: String)
    /// The custom set installed without the cold-boot placeholder, enabled: it falls back to Hey Meta after the case
    /// or a power-off until installed again.
    case olderCustom
    /// A set the installer knows, but the wake feature isn't enabled: a change was interrupted, and the wake word may
    /// not work until a set is installed again.
    case incomplete
    /// Resources ReGlass doesn't recognise. ReGlass leaves them alone.
    case unknown
    /// No wake word resources are installed, as after a factory reset. The factory set can be restored without
    /// overwriting an existing artifact or feature.
    case empty
}

/// Where an install is.
public enum WakeWordProgress: Sendable, Equatable {
    /// Taking the link and checking the glasses. Nothing has changed yet.
    case connecting
    /// Sending the files: the share of the set's bytes handed to the link, 0…1.
    case sending(Double)
    /// Switching the wake word on and reading it back.
    case finishing
}

/// Recognises the sets on the glasses: Meta's factory set, and the custom sets ReGlass knows. A custom set is
/// installed under `base-xxxxx` (5 lowercase hex digits).
enum WakeWordCatalog {
    enum Family: Equatable {
        case factory
        /// A known custom set, by artifact id.
        case custom(String)
    }

    /// A custom set's identity on the glasses: its artifact id and base version.
    struct CustomFamily: Equatable, Sendable, Codable {
        let artifactId: String
        let version: String
    }

    /// The custom sets the library knows besides the proven one: the imported set, and every set ReGlass has started
    /// to install. Kept so the installer still recognises (and may replace) a set whose files were removed since.
    private static let registered = Locked<[CustomFamily]>([])

    static func register(_ families: [CustomFamily]) {
        registered.withLock { $0 = families }
    }

    static var customFamilies: [CustomFamily] {
        let proven = CustomFamily(artifactId: WakeWordSet.custom.artifact, version: WakeWordSet.custom.baseVersion)
        return [proven] + registered.current.filter { $0 != proven }
    }

    /// The installed English language artifact and feature (with the optional type 6 cold-boot placeholder),
    /// or nil when the resources aren't a known shape.
    struct Known: Equatable {
        let family: Family
        let version: String
        let enabled: Bool
        let bootPlaceholderInstalled: Bool
    }

    static func known(_ inventory: ResourceInventory) -> Known? {
        let languageFeatures = inventory.features.filter { $0.name == ResourceOta.feature }
        let placeholderFeatures = inventory.features.filter { $0.name == ResourceOta.bootPlaceholderFeature }
        guard languageFeatures.count == 1, placeholderFeatures.count <= 1,
              languageFeatures.count + placeholderFeatures.count == inventory.features.count else {
            return nil
        }
        let placeholderArtifacts = inventory.artifacts.filter {
            $0.id == ResourceOta.bootPlaceholderArtifact && $0.version == ResourceOta.bootPlaceholderVersion
        }
        let languageArtifacts = inventory.artifacts.filter {
            !($0.id == ResourceOta.bootPlaceholderArtifact && $0.version == ResourceOta.bootPlaceholderVersion)
        }
        guard languageArtifacts.count == 1, placeholderArtifacts.count == placeholderFeatures.count,
              let artifact = languageArtifacts[0].id, let version = languageArtifacts[0].version,
              let family = family(artifact: artifact, version: version) else {
            return nil
        }
        return Known(
            family: family,
            version: version,
            enabled: languageFeatures[0].status == 1,
            bootPlaceholderInstalled: placeholderFeatures.count == 1
        )
    }

    /// Whether the glasses list no resources at all (nothing installed, nothing to replace).
    static func isEmpty(_ inventory: ResourceInventory) -> Bool {
        inventory.artifacts.isEmpty && inventory.features.isEmpty
    }

    static func classify(_ inventory: ResourceInventory) -> InstalledWakeWord {
        if isEmpty(inventory) { return .empty }
        guard let known = known(inventory) else { return .unknown }
        guard known.enabled else { return .incomplete }
        switch known.family {
        case .factory: return .heyMeta
        // A custom install without the type 6 placeholder pre-dates the cold-boot fix and will fall back
        // to Hey Meta after case sleep or power-off until installed again.
        case .custom(let artifact): return known.bootPlaceholderInstalled ? .custom(artifact: artifact) : .olderCustom
        }
    }

    /// The readback that confirms an install: the new language artifact and version, the type 6 cold-boot
    /// placeholder present, and the language feature enabled.
    static func confirms(_ inventory: ResourceInventory, artifact: String, version: String) -> Bool {
        guard let known = known(inventory), known.enabled, known.bootPlaceholderInstalled else { return false }
        return inventory.artifacts.contains { $0.id == artifact && $0.version == version }
    }

    private static func family(artifact: String, version: String) -> Family? {
        if artifact == WakeWordSet.factoryArtifact { return WakeWordSet.isFactoryVersion(version) ? .factory : nil }
        let known = customFamilies.contains { $0.artifactId == artifact && isDeployment(version, base: $0.version) }
        return known ? .custom(artifact) : nil
    }

    private static func isDeployment(_ version: String, base: String) -> Bool {
        if version == base { return true }
        let prefix = base + "-"
        guard version.hasPrefix(prefix) else { return false }
        let suffix = version.dropFirst(prefix.count).utf8
        return suffix.count == 5 && suffix.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: Firmware

    /// The MCU version in the svc100 build fingerprint `meta/orca/orca:none/<version>/none:<flavor>/none`, or nil
    /// for any other shape.
    static func firmwareVersion(fromBuild build: String) -> String? {
        let parts = build.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        guard parts.count == 6, parts[0].lowercased() == "meta", parts[1].lowercased() == "orca",
              parts[2].lowercased() == "orca:none", parts[5].lowercased() == "none" else { return nil }
        let flavor = parts[4].split(separator: ":", omittingEmptySubsequences: false)
        guard flavor.count == 2, flavor[0].lowercased() == "none",
              ["user", "userdebug", "eng"].contains(flavor[1].lowercased()) else { return nil }
        let version = parts[3]
        guard (1...19).contains(version.utf8.count), version.utf8.allSatisfy({ (48...57).contains($0) }),
              version != "0", Int64(version) != nil else { return nil }
        return version
    }

    /// Any well-formed Audio (orca) build can be queried with an empty `DeviceInfoRequest` on svc22.
    /// Installing a set also requires `WakeWordSet.firmware` to match the glasses' build.
    static func isSupported(build: String?) -> Bool {
        build.flatMap(firmwareVersion(fromBuild:)) != nil
    }
}
