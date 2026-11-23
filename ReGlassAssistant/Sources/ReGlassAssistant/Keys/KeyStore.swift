import Foundation
import Security

/// The API keys the assistant needs.
public enum AssistantKey: String, CaseIterable, Sendable, Identifiable {
    case anthropic
    case elevenLabs

    public var id: String { rawValue }
}

public enum KeyStoreError: Error, Equatable, Sendable {
    /// The iPhone hasn't been unlocked since it restarted, so the Keychain won't hand the key over yet.
    case locked
    /// Empty or obviously not a key.
    case invalid
    case keychain(OSStatus)
}

/// The assistant's keys in the iPhone Keychain: this device only, readable after the first unlock since a restart
/// (so the assistant works with the iPhone locked in a pocket), never synced to iCloud or put in backups.
/// Nothing here logs a key; callers only ever show the last four characters.
public struct KeyStore: Sendable {
    public static let shared = KeyStore()

    private let service: String

    /// `service` defaults to the app's bundle identifier + ".assistant", so each build keeps its own keys.
    public init(service: String = (Bundle.main.bundleIdentifier ?? "reglass") + ".assistant") {
        self.service = service
    }

    /// The key, or nil if none is saved. Throws `.locked` before the first unlock after a restart.
    public func read(_ key: AssistantKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw KeyStoreError.locked
        default:
            throw KeyStoreError.keychain(status)
        }
    }

    /// Saves or replaces the key. Whitespace and line breaks from pasting are dropped.
    public func save(_ value: String, for key: AssistantKey) throws {
        let cleaned = Self.clean(value)
        guard cleaned.count >= 8, !cleaned.contains(where: \.isWhitespace) else { throw KeyStoreError.invalid }
        let data = Data(cleaned.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            AssistantLog.add("\(key.logName) key replaced in the Keychain")
        case errSecItemNotFound:
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.error(added) }
            AssistantLog.add("\(key.logName) key saved in the Keychain")
        default:
            throw Self.error(status)
        }
    }

    public func remove(_ key: AssistantKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        AssistantLog.add("\(key.logName) key removed from the Keychain")
    }

    /// Whether a key is saved. Before the first unlock after a restart that can't be told, and it counts as saved:
    /// the screens say to unlock the iPhone instead of asking for a key that's there.
    public func has(_ key: AssistantKey) -> Bool {
        do {
            return try read(key) != nil
        } catch {
            return true
        }
    }

    /// "•••• abcd": the only form a key is ever shown in. Nil when no key is saved or it can't be read yet.
    public func hint(for key: AssistantKey) -> String? {
        guard let value = try? read(key) else { return nil }
        return Self.hint(value)
    }

    public static func hint(_ value: String) -> String {
        "•••• " + String(value.suffix(4))
    }

    /// Strips what pasting tends to add: spaces, line breaks, quotes.
    public static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    }

    // MARK: Private

    private func baseQuery(_ key: AssistantKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func error(_ status: OSStatus) -> KeyStoreError {
        status == errSecInteractionNotAllowed ? .locked : .keychain(status)
    }
}

extension AssistantKey {
    /// The company the key is from, for the screens ("Needs your ElevenLabs key.") and the log.
    public var providerName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    var logName: String { providerName }
}
