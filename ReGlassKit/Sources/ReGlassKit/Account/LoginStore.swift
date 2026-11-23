import Foundation

/// The encrypted Meta login cache: one sealed file holding the FRLA, plus the FRLA→pairing-token exchange the
/// ownership layer uses. A generation counter makes a cancelled or replaced sign-in unable to repopulate the
/// cache after the fact, and lets a late async result be ignored.
///
/// State is behind `lock`, so the type is `Sendable` without being an actor.
final class LoginStore: @unchecked Sendable {
    private let file: URL
    private let vault = Vault(purpose: "meta-login")
    private let lock = NSLock()
    private var generation: UInt64 = 0

    init(directory: URL) {
        file = directory.appendingPathComponent("meta-login.sealed")
    }

    /// Whether a login is cached. Says nothing about whether Meta still honours it.
    var hasLogin: Bool { readFrla() != nil }

    /// Starts a fresh sign-in attempt, invalidating any earlier pending one. Returns the token to check later.
    func beginAttempt() -> UInt64 { lock.withLock { generation &+= 1; return generation } }

    /// Invalidates the current attempt without starting a new one (cancel / logout).
    func invalidatePending() { lock.withLock { generation &+= 1 } }

    func isCurrent(_ token: UInt64) -> Bool { lock.withLock { generation == token } }

    /// The native flow handed us an FRLA directly: cache it if this attempt is still current.
    func commitFrla(_ frla: String, attempt: UInt64) throws {
        try lock.withLock {
            guard generation == attempt else { throw ReGlassError.cancelled }
            try writeFrla(frla)
        }
    }

    /// The native flow handed us an OIDC code: exchange it for an FRLA, then cache it if still current.
    func commitAuthCode(_ code: String, attempt: UInt64) async throws {
        guard isCurrent(attempt) else { throw ReGlassError.cancelled }
        let frla = try await exchangeAuthCode(code)
        try commitFrla(frla, attempt: attempt)
    }

    /// The pairing token for the ownership layer. Throws `.signInRequired` when there is no usable login,
    /// `.keyUnavailable` when the iPhone hasn't been unlocked since boot.
    func pairingToken() async throws -> Token {
        let bytes: [UInt8]?
        do {
            bytes = try vault.read(file)
        } catch Vault.Failure.keyUnavailable {
            throw ReGlassError.keyUnavailable
        } catch {
            throw ReGlassError.signInRequired
        }
        guard let bytes else { throw ReGlassError.signInRequired }
        let frla = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frla.isEmpty else { throw ReGlassError.signInRequired }
        return try await exchangeFrla(frla)
    }

    /// Forget the cached login. The owner key, kept under a different purpose, is untouched.
    func clear() {
        lock.withLock {
            generation &+= 1
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func readFrla() -> String? {
        // A cache sealed by a previous install, or one we can't open yet, counts as "no login": sign in again.
        guard let bytes = (try? vault.read(file)) ?? nil else { return nil }
        let frla = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return frla.isEmpty ? nil : frla
    }

    private func writeFrla(_ frla: String) throws {
        try vault.write(Array(frla.utf8), to: file)
    }
}
