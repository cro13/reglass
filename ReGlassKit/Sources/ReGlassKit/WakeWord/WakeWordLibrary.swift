import Foundation

/// The wake word sets on this iPhone: at most one factory set ("Hey Meta") and one custom set, each a folder in
/// Application Support with ReGlass's own `manifest.json` and the eight files. A set arrives from Files or an
/// explicit factory download from Meta, and is checked in full before anything is copied. ReGlass includes no
/// wake word files and never uploads them; the folder is left out of iCloud and computer backups.
///
/// Stateless apart from the files, so it is `Sendable` and every method may run on any thread.
public final class WakeWordLibrary: Sendable {
    /// A set kept on this iPhone, as the app shows it.
    public struct StoredSet: Equatable, Sendable {
        /// `.heyMeta` for the factory set.
        public let wakeWord: WakeWord
        /// "Hey Meta", or the custom set's name from its manifest.
        public let name: String
        /// The id the glasses list the set under.
        public let artifactId: String
        /// What an install sends, in bytes.
        public let byteCount: Int
        /// The glasses firmware build the set is made for; it installs only on glasses running that build.
        public let firmware: String
        public let addedAt: Date?
    }

    private let root: URL

    /// `directory` is ReGlass's own folder for wake word sets, e.g. Application Support/ReGlass/WakeWord.
    public init(directory: URL) {
        root = directory
        registerFamilies()
    }

    /// The set kept for `wakeWord`, or nil when there is none (or its manifest no longer checks out).
    public func stored(_ wakeWord: WakeWord) -> StoredSet? {
        guard let kept = try? readStored(wakeWord) else { return nil }
        return StoredSet(wakeWord: wakeWord, name: kept.checked.name, artifactId: kept.checked.set.artifact,
                         byteCount: kept.checked.set.totalBytes, firmware: kept.checked.set.firmware,
                         addedAt: kept.manifest.addedAt)
    }

    /// Downloads Meta's factory set for the firmware the glasses report (`build`, their svc100 build string), using
    /// the wearer's Meta login and this pair's serial, and checks it against Meta's own data. This only prepares a
    /// restore set on the iPhone, made for that firmware; it never touches the glasses or installs firmware.
    public func downloadFactorySet(account: MetaAccount, build: String, serial: String,
                                   progress: @Sendable (String) async -> Void) async throws -> StoredSet {
        guard let firmware = WakeWordCatalog.firmwareVersion(fromBuild: build) else {
            throw ReGlassError.wakeWordUnavailable
        }
        do {
            let token = try await account.pairingToken()
            guard token.universe == "ar", account.status == .signedIn else { throw ReGlassError.signInRequired }
            let download = try await FactoryWakeWordDownload().fetch(token: token.value, serial: serial,
                                                                       firmware: firmware, progress: progress)
            try Task.checkCancellation()
            guard let set = WakeWordSet.factory(firmware: firmware, resourceVersion: download.resourceVersion,
                                                contents: download.contents) else {
                throw FactoryWakeWordDownload.Failure.package
            }
            let checked = WakeWordManifest.Checked(wakeWord: .heyMeta, name: "Hey Meta", set: set)
            try keep(checked, contents: set.entries.map { download.contents[$0.filename] ?? [] })
            guard let result = stored(.heyMeta) else { throw ReGlassError.wakeWordFilesDamaged }
            kitLog("wakeword", "factory set for firmware \(firmware) downloaded and checked (\(set.baseVersion)); "
                   + "nothing sent to glasses")
            return result
        } catch is CancellationError { throw ReGlassError.cancelled }
        catch let error as FactoryWakeWordDownload.Failure {
            if error == .signIn { throw ReGlassError.signInRequired }
            throw ReGlassError.wakeWordDownloadFailed(error.errorDescription ?? "The factory download couldn't finish.")
        } catch let error as ReGlassError { throw error }
        catch { throw ReGlassError.wakeWordDownloadFailed("The factory set couldn't be saved. Try again.") }
    }

    /// Checks the set at `url` (a folder, or a `.zip` holding one) and keeps a copy, replacing the set of the same
    /// kind. The manifest's role says which kind it is; a folder without a manifest is taken as the factory set only
    /// if its eight files are exactly the pinned factory files. Throws `.wakeWordSetInvalid` with the reason, and
    /// copies nothing then.
    public func importSet(from url: URL) async throws -> StoredSet {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let source = try SetSource.open(url)
            let manifest = try source.read(WakeWordManifest.filename, limit: WakeWordManifest.maxBytes)
            let checked: WakeWordManifest.Checked
            let contents: [[UInt8]]
            if let manifest {
                checked = try WakeWordManifest.decode(manifest).checked()
                contents = try Self.read(checked.set, from: source)
            } else {
                // No manifest: only Meta's factory files, byte for byte, are recognised.
                checked = WakeWordManifest.Checked(wakeWord: .heyMeta, name: "Hey Meta", set: WakeWordSet.heyMeta)
                do { contents = try Self.read(checked.set, from: source) } catch {
                    throw WakeWordManifest.invalid("There's no manifest.json in it.")
                }
            }
            try Task.checkCancellation()
            try keep(checked, contents: contents)
            kitLog("wakeword", "\(checked.wakeWord.logName) set imported: \(checked.set.entries.count) files, "
                     + "\(checked.set.totalBytes) bytes")
            guard let stored = stored(checked.wakeWord) else { throw WakeWordFault.damagedSet("kept copy") }
            return stored
        } catch let error as ReGlassError {
            kitLog("wakeword", "set not imported: \(error)")
            throw error
        } catch is CancellationError {
            throw ReGlassError.cancelled
        } catch {
            kitLog("wakeword", "set not imported: \(type(of: error))")
            throw WakeWordManifest.invalid("Its files can't be read.")
        }
    }

    /// Deletes the kept set for `wakeWord` from this iPhone. Nothing changes on the glasses.
    public func remove(_ wakeWord: WakeWord) throws {
        let folder = folder(for: wakeWord)
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw ReGlassError.protocolFailure("the set's folder could not be removed")
            }
        }
        registerFamilies()
        kitLog("wakeword", "\(wakeWord.logName) set removed from this iPhone")
    }

    /// Reads the kept set for `wakeWord` and checks every file again, without touching the glasses. Throws
    /// `.wakeWordFilesDamaged` when a file is missing or changed.
    public func check(_ wakeWord: WakeWord) async throws {
        do { _ = try set(for: wakeWord).load() } catch {
            throw ReGlassError.wakeWordFilesDamaged
        }
    }

    // MARK: For the installer

    /// The kept set for `wakeWord`, with its folder. Its files are checked again by `load()`.
    func set(for wakeWord: WakeWord) throws -> WakeWordSet {
        guard let kept = try readStored(wakeWord) else { throw WakeWordFault.damagedSet("no \(wakeWord.logName) set") }
        return kept.checked.set.at(folder(for: wakeWord))
    }

    /// Remembers a custom set's identity before it is sent, so the installer keeps recognising it on the glasses
    /// (and may replace it) after its files are removed from this iPhone.
    func noteInstalling(_ set: WakeWordSet) {
        let family = WakeWordCatalog.CustomFamily(artifactId: set.artifact, version: set.baseVersion)
        var families = remembered().filter { $0 != family }
        families.append(family)
        let kept = Array(families.suffix(32))
        if let data = try? JSONEncoder().encode(kept) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: rememberedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        registerFamilies()
    }

    // MARK: Storage

    private func folder(for wakeWord: WakeWord) -> URL {
        root.appendingPathComponent(wakeWord == .heyMeta ? "Factory" : "Custom", isDirectory: true)
    }

    private var rememberedURL: URL { root.appendingPathComponent("installed-sets.json") }

    private struct Kept {
        let manifest: WakeWordManifest
        let checked: WakeWordManifest.Checked
    }

    private func readStored(_ wakeWord: WakeWord) throws -> Kept? {
        let url = folder(for: wakeWord).appendingPathComponent(WakeWordManifest.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let manifest = try WakeWordManifest.decode(try Data(contentsOf: url).byteArray)
        let checked = try manifest.checked()
        guard manifest.format == WakeWordManifest.format, checked.wakeWord == wakeWord else {
            throw WakeWordFault.damagedSet("kept manifest")
        }
        return Kept(manifest: manifest, checked: checked)
    }

    /// Writes the checked files and ReGlass's manifest into a fresh folder, then swaps it in for the old set.
    private func keep(_ checked: WakeWordManifest.Checked, contents: [[UInt8]]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup()
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for (entry, bytes) in zip(checked.set.entries, contents) {
            try Data(bytes).write(to: staging.appendingPathComponent(entry.filename),
                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try WakeWordManifest.stored(checked, addedAt: Date()).encoded()
            .write(to: staging.appendingPathComponent(WakeWordManifest.filename),
                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let destination = folder(for: checked.wakeWord)
        if manager.fileExists(atPath: destination.path) {
            let old = root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: destination, to: old)
            do { try manager.moveItem(at: staging, to: destination) } catch {
                try? manager.moveItem(at: old, to: destination)
                throw error
            }
            try? manager.removeItem(at: old)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        registerFamilies()
    }

    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func remembered() -> [WakeWordCatalog.CustomFamily] {
        guard let data = try? Data(contentsOf: rememberedURL), data.count <= 64 * 1024 else { return [] }
        return (try? JSONDecoder().decode([WakeWordCatalog.CustomFamily].self, from: data)) ?? []
    }

    /// Tells the catalog which custom sets are ReGlass's: the imported one and every one it has started to send.
    private func registerFamilies() {
        var families = remembered()
        if let kept = try? readStored(.custom) {
            let family = WakeWordCatalog.CustomFamily(artifactId: kept.checked.set.artifact,
                                                      version: kept.checked.set.baseVersion)
            if !families.contains(family) { families.append(family) }
        }
        WakeWordCatalog.register(families)
    }

    // MARK: Reading the picked set

    /// Reads each of the set's files from `source` and checks its size, SHA-256 and (for the wake model) its first
    /// bytes. Returns the contents in the set's order.
    private static func read(_ set: WakeWordSet, from source: SetSource) throws -> [[UInt8]] {
        try set.entries.map { entry in
            guard let bytes = try source.read(entry.filename, limit: WakeWordSet.maxFileBytes) else {
                throw WakeWordManifest.invalid("\(entry.filename) is missing.")
            }
            guard bytes.count == entry.size else { throw WakeWordManifest.invalid("\(entry.filename) is the wrong size.") }
            guard WakeWordSet.sha256(bytes) == entry.sha256 else {
                throw WakeWordManifest.invalid("\(entry.filename) doesn't match its SHA-256.")
            }
            if entry.filename == ResourceOta.wakeModelFilename, !WakeWordSet.looksLikeWakeModel(bytes) {
                throw WakeWordManifest.invalid("\(entry.filename) doesn't look like a wake word model.")
            }
            return bytes
        }
    }
}

/// Where a picked set's files come from: a folder (read through file coordination, so files kept in iCloud Drive are
/// fetched first), or a ZIP archive whose files sit at its top or in one folder inside it.
private enum SetSource {
    case folder(URL)
    case zip(ZipArchive, prefix: String)

    static let maxArchiveBytes = 16 * 1024 * 1024

    static func open(_ url: URL) throws -> SetSource {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder { return .folder(url) }
        guard let bytes = try coordinatedRead(url, limit: maxArchiveBytes) else {
            throw WakeWordManifest.invalid("It can't be opened.")
        }
        guard bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw WakeWordManifest.invalid("Pick a folder, or a .zip with the set in it.")
        }
        let archive: ZipArchive
        do { archive = try ZipArchive(bytes) } catch {
            throw WakeWordManifest.invalid("Its ZIP archive can't be opened. Compress the folder again and retry.")
        }
        return .zip(archive, prefix: setFolder(in: archive))
    }

    /// The set's files are at the archive's top, or in the one folder that holds them (as when a folder is
    /// compressed). Finder's `__MACOSX` extras are ignored.
    private static func setFolder(in archive: ZipArchive) -> String {
        let markers = ResourceOta.filenames.union([WakeWordManifest.filename])
        let files = archive.entries.filter { !$0.isDirectory && !$0.name.hasPrefix("__MACOSX/") }
        if files.contains(where: { markers.contains($0.name) }) { return "" }
        let folders = Set(files.compactMap { entry -> String? in
            let parts = entry.name.split(separator: "/")
            guard parts.count == 2, markers.contains(String(parts[1])) else { return nil }
            return String(parts[0]) + "/"
        })
        return folders.count == 1 ? folders.first! : ""
    }

    /// The named file's bytes, or nil when the set has no such file.
    func read(_ name: String, limit: Int) throws -> [UInt8]? {
        switch self {
        case .folder(let folder):
            return try Self.coordinatedRead(folder.appendingPathComponent(name), limit: limit)
        case .zip(let archive, let prefix):
            guard let entry = archive.entry(named: prefix + name) else { return nil }
            do { return try archive.contents(of: entry, limit: limit) } catch ZipArchive.Failure.tooLarge {
                throw WakeWordManifest.invalid("\(name) is larger than any file ReGlass sends.")
            } catch {
                throw WakeWordManifest.invalid("\(name) can't be read from the ZIP archive.")
            }
        }
    }

    private static func coordinatedRead(_ url: URL, limit: Int) throws -> [UInt8]? {
        var result: Result<[UInt8]?, Error> = .success(nil)
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordination) { readable in
            result = Result<[UInt8]?, Error> {
                let values = try? readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { return nil }
                guard (values?.fileSize ?? 0) <= limit else {
                    throw WakeWordManifest.invalid("\(url.lastPathComponent) is larger than any file ReGlass sends.")
                }
                return try Data(contentsOf: readable).byteArray
            }
        }
        if let coordination {
            if coordination.domain == NSCocoaErrorDomain, coordination.code == NSFileReadNoSuchFileError { return nil }
            throw WakeWordManifest.invalid("\(url.lastPathComponent) can't be read.")
        }
        return try result.get()
    }
}
