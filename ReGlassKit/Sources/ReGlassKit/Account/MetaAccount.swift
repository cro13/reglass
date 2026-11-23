import Foundation

/// ReGlass's Meta account: the native email-code sign-in and the encrypted login it caches on this device.
///
/// `status` and `statusUpdates()` are readable from anywhere. The sign-in lifecycle (`beginSignIn`, `cancelSignIn`,
/// `signOut`) runs on the main actor, since it owns the main-actor `MetaSignIn` conversation the app renders.
public final class MetaAccount: Sendable {
    public enum Status: Equatable, Sendable {
        case signedOut, signingIn, signedIn
        /// Short, user-facing reason. Never carries server text, tokens, or personal data.
        case failed(String)
    }

    private struct Core {
        var status: Status
        var listeners: [UUID: AsyncStream<Status>.Continuation] = [:]
    }

    private let store: LoginStore
    private let core: Locked<Core>
    @MainActor private var activeSignIn: MetaSignIn? = nil

    public init(storageDirectory: URL) {
        store = LoginStore(directory: storageDirectory)
        core = Locked(Core(status: store.hasLogin ? .signedIn : .signedOut))
    }

    public var status: Status { core.withLock { $0.status } }

    /// Status changes, starting with the current one. Finishes when the consumer stops iterating.
    public func statusUpdates() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let id = UUID()
            let current = core.withLock { core -> Status in core.listeners[id] = continuation; return core.status }
            continuation.yield(current)
            continuation.onTermination = { [core] _ in core.withLock { $0.listeners[id] = nil } }
        }
    }

    /// Start a new sign-in conversation. Any conversation already in progress is abandoned first.
    @MainActor public func beginSignIn() throws -> MetaSignIn {
        if let error = MetaClient.signInDataError { throw error }
        guard let credentials = MetaClientCredentials.current else { throw ReGlassError.missingClientCredentials }
        activeSignIn?.cancel()
        let attempt = store.beginAttempt()
        let signIn = MetaSignIn(client: BloksClient(token: credentials.firstRunLogin),
                                next: metaAuthorizeURL(), deviceID: Self.deviceID())
        signIn.onOutcome = { [weak self] outcome in self?.handle(outcome, attempt: attempt) }
        activeSignIn = signIn
        setStatus(.signingIn)
        kitLog("account", "sign-in started")
        return signIn
    }

    /// Abandon the current sign-in. Returns to the previous signed-in/out state.
    @MainActor public func cancelSignIn() {
        activeSignIn?.cancel()
        activeSignIn = nil
        store.invalidatePending()
        setStatus(store.hasLogin ? .signedIn : .signedOut)
        kitLog("account", "sign-in cancelled")
    }

    /// Forget the cached login only. The owner key kept for the glasses is untouched.
    @MainActor public func signOut() {
        activeSignIn?.cancel()
        activeSignIn = nil
        store.clear()
        setStatus(.signedOut)
        kitLog("account", "signed out; owner key retained")
    }

    /// The pairing token for the ownership layer. `GlassesOwnership` calls this to drive Meta's pairing backend;
    /// `Token.value` is the user access token and `Token.universe` the universe it belongs to ("ar").
    /// Throws `.signInRequired` when there is no usable login and `.keyUnavailable` before first unlock.
    func pairingToken() async throws -> Token { try await store.pairingToken() }

    // MARK: Outcome handling

    @MainActor private func handle(_ outcome: BloksSession.Outcome, attempt: UInt64) {
        guard store.isCurrent(attempt) else { return } // a cancelled or replaced sign-in reported late
        activeSignIn = nil
        switch outcome {
        case .cancelled:
            store.invalidatePending()
            setStatus(store.hasLogin ? .signedIn : .signedOut)
        case .failed(let reason):
            store.invalidatePending()
            setStatus(.failed(reason))
        case .token(let frla):
            do { try store.commitFrla(frla, attempt: attempt); signedIn() }
            catch { setStatus(.failed(Self.reason(for: error))) }
        case .code(let code):
            setStatus(.signingIn)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.store.commitAuthCode(code, attempt: attempt)
                    guard self.store.isCurrent(attempt) else { return }
                    self.signedIn()
                } catch {
                    guard self.store.isCurrent(attempt) else { return }
                    self.setStatus(.failed(Self.reason(for: error)))
                }
            }
        }
    }

    private func signedIn() {
        setStatus(.signedIn)
        kitLog("account", "encrypted login cached; enrollment not attempted")
    }

    private func setStatus(_ status: Status) {
        let (changed, listeners) = core.withLock { core -> (Bool, [AsyncStream<Status>.Continuation]) in
            guard core.status != status else { return (false, []) }
            core.status = status
            return (true, Array(core.listeners.values))
        }
        guard changed else { return }
        for continuation in listeners { continuation.yield(status) }
        kitLog("account", "status: \(status.logName)")
    }

    private static func reason(for error: Error) -> String {
        if let kitError = error as? ReGlassError { return kitError.errorDescription ?? defaultReason }
        return defaultReason
    }
    private static let defaultReason = "Meta sign-in couldn’t be completed. Try again."

    private static func deviceID() -> String {
        let key = "reglass.meta.device-id"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}

private extension MetaAccount.Status {
    var logName: String {
        switch self {
        case .signedOut: return "signed out"
        case .signingIn: return "signing in"
        case .signedIn: return "signed in"
        case .failed: return "failed"
        }
    }
}
