import Foundation

/// What ReGlass knows about one pair of glasses it set up. The owner key is stored once, separately; a record only
/// says which glasses it belongs to and how far setup got.
struct IdentityRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Identity is known and the ownership exchange is pending. Saved before svc36 message 0x2002.
        case pending
        /// Ownership transferred; the trusted reconnect hasn't confirmed it yet.
        case unverified
        /// Confirmed by a trusted reconnect: trust both ways, READY, matching serial, measured battery.
        case verified
        /// The glasses turned the key down (set up with another app since).
        case refused
    }

    /// The CBPeripheral identifier the glasses were last verified under.
    var glassesID: UUID
    var serial: String
    var state: State
    var createdAt: Date
}

/// ReGlass's sealed identity files: one owner key and the records of the glasses that know it.
///
/// Rules this type enforces:
/// - There is at most one owner key. It is written only when none exists, read back before it is used, and never
///   deleted or replaced. An unreadable key file is an error, never a reason to make a new key.
/// - Records are replaced whole, by serial, in one atomic write.
///
/// Every operation runs under one process-wide lock, so read-modify-write sequences don't interleave.
enum IdentityStore {
    private static let vault = Vault(purpose: "owner-identity")
    private static let lock = NSRecursiveLock()

    private static var directory: URL {
        get throws { try ReGlassKitStorage.directory.appendingPathComponent("identity", isDirectory: true) }
    }
    private static var keyFile: URL { get throws { try directory.appendingPathComponent("owner-key.sealed") } }
    private static var recordsFile: URL { get throws { try directory.appendingPathComponent("glasses.sealed") } }

    // MARK: Owner key

    /// The stored owner key, or nil when ReGlass has never made one.
    /// Throws `.keyUnavailable` before the first unlock, `.protocolFailure` when the file is damaged.
    static func ownerKey() throws -> OwnerKey? {
        try lock.withLock {
            guard let pem = try read(try keyFile) else { return nil }
            return try OwnerKey.load(pem: pem)
        }
    }

    /// The stored owner key, or a new one sealed to disk and read back before it is returned.
    /// `reused` says which. Never overwrites an existing or unreadable key file.
    static func ownerKeyCreatingIfNeeded() throws -> (key: OwnerKey, reused: Bool) {
        try lock.withLock {
            let file = try keyFile
            if FileManager.default.fileExists(atPath: file.path) {
                guard let key = try ownerKey() else { throw ReGlassError.keyUnavailable }
                return (key, true)
            }
            let fresh = OwnerKey.generate()
            try write(fresh.pem, to: file)
            // Only a key that reads back from disk may go near the glasses or Meta.
            guard let stored = try ownerKey(), stored.publicKey64 == fresh.publicKey64 else {
                throw ReGlassError.protocolFailure("the new owner key did not read back")
            }
            kitLog("ownership", "new owner key sealed on this iPhone")
            return (stored, false)
        }
    }

    // MARK: Records

    static func records() throws -> [IdentityRecord] {
        try lock.withLock {
            guard let bytes = try read(try recordsFile) else { return [] }
            do {
                return try JSONDecoder().decode([IdentityRecord].self, from: Data(bytes))
            } catch {
                throw ReGlassError.protocolFailure("the saved glasses list is damaged")
            }
        }
    }

    static func record(serial: String) throws -> IdentityRecord? {
        try records().first { $0.serial == serial }
    }

    /// Saves `record`, replacing any record with the same serial.
    static func save(_ record: IdentityRecord) throws {
        try lock.withLock {
            var all = try records().filter { $0.serial != record.serial }
            all.append(record)
            try write(try JSONEncoder().encode(all).byteArray, to: try recordsFile)
        }
    }

    /// Changes the state of the record for `serial`, if there is one.
    static func setState(_ state: IdentityRecord.State, serial: String) throws {
        try lock.withLock {
            guard var record = try record(serial: serial), record.state != state else { return }
            record.state = state
            try save(record)
        }
    }

    /// Drops the record for `serial`. The owner key stays.
    static func remove(serial: String) throws {
        try lock.withLock {
            let remaining = try records().filter { $0.serial != serial }
            try write(try JSONEncoder().encode(remaining).byteArray, to: try recordsFile)
        }
    }

    // MARK: Files

    private static func read(_ url: URL) throws -> [UInt8]? {
        do {
            return try vault.read(url)
        } catch Vault.Failure.keyUnavailable {
            throw ReGlassError.keyUnavailable
        } catch Vault.Failure.unreadable {
            throw ReGlassError.protocolFailure("a saved identity file is damaged")
        }
    }

    private static func write(_ bytes: [UInt8], to url: URL) throws {
        do {
            try vault.write(bytes, to: url)
        } catch Vault.Failure.keyUnavailable {
            throw ReGlassError.keyUnavailable
        }
    }
}
