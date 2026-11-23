import CryptoKit
import Darwin
import Foundation
import Security

/// Encrypts small files at rest: AES-256-GCM with a key per purpose, kept in the Keychain on this device only.
///
/// Keys are readable after the first unlock, so a background reconnect can open the owner key, and they are never
/// synced or restored to another device. A blob is `GLV1 ‖ 12-byte nonce ‖ ciphertext ‖ 16-byte tag`, with `GLV1`
/// as associated data.
struct Vault: Sendable {
    enum Failure: Error, Equatable {
        /// The Keychain refused (usually: the iPhone hasn't been unlocked since it started).
        case keyUnavailable(OSStatus)
        /// The file isn't a vault blob, is damaged, or was sealed with a key this device no longer has.
        case unreadable
    }

    /// The Keychain item for this purpose, e.g. "owner-identity" or "meta-login".
    let purpose: String

    func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(Data(plaintext), using: try key(), authenticating: Data(Self.magic))
        return Self.magic + [UInt8](box.nonce) + box.ciphertext.byteArray + box.tag.byteArray
    }

    func open(_ blob: [UInt8]) throws -> [UInt8] {
        let headerEnd = Self.magic.count + Self.nonceBytes
        guard blob.count >= headerEnd + Self.tagBytes, Array(blob[0..<Self.magic.count]) == Self.magic else {
            throw Failure.unreadable
        }
        let key = try key()
        do {
            let tagStart = blob.count - Self.tagBytes
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(blob[Self.magic.count..<headerEnd])),
                ciphertext: Data(blob[headerEnd..<tagStart]),
                tag: Data(blob[tagStart...])
            )
            return try AES.GCM.open(box, using: key, authenticating: Data(Self.magic)).byteArray
        } catch {
            throw Failure.unreadable
        }
    }

    /// Reads and opens `url`; nil when the file doesn't exist.
    func read(_ url: URL) throws -> [UInt8]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try open(try Data(contentsOf: url).byteArray)
    }

    /// Seals and writes `plaintext` to `url` atomically, owner-only, and flushed to disk before returning.
    func write(_ plaintext: [UInt8], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(try seal(plaintext)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.flush(url, in: directory)
    }

    // MARK: Key

    private func key() throws -> SymmetricKey {
        try Self.keyLock.withLock {
            if let stored = try Self.loadKey(purpose) { return SymmetricKey(data: stored) }
            let key = SymmetricKey(size: .bits256)
            try Self.storeKey(purpose, key.withUnsafeBytes { Data($0) })
            return key
        }
    }

    private static func query(_ purpose: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: purpose,
        ]
    }

    private static func loadKey(_ purpose: String) throws -> Data? {
        var query = query(purpose)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keyUnavailable(status) }
        return data
    }

    private static func storeKey(_ purpose: String, _ key: Data) throws {
        var query = query(purpose)
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keyUnavailable(status) }
    }

    /// fsync the file and its directory, so a crash right after a write can't lose the only copy of a key.
    private static func flush(_ url: URL, in directory: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static let magic: [UInt8] = Array("GLV1".utf8)
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let keychainService = "reglass.vault"
    // One lock for every purpose, so two callers never both generate a key for the same one.
    private static let keyLock = NSLock()
}

/// ReGlass's Application Support folder for ReGlassKit's files.
enum ReGlassKitStorage {
    static var directory: URL {
        get throws {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent("ReGlassKit", isDirectory: true)
        }
    }
}
