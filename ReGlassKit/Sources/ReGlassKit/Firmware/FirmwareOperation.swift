import Foundation

/// Provides exclusive access to the glasses, a write watchdog and link-loss detection for firmware operations.
enum FirmwareOperation {
    /// At most one firmware installer holds the glasses through transfer, reboot and confirmation.
    private static let busy = Locked(false)

    /// Runs `work` as THE firmware operation, or throws `FirmwareInstallFault.busy` if another one is running.
    static func exclusive<T>(_ work: () async throws -> T) async throws -> T {
        try busy.withLock { running in
            guard !running else { throw FirmwareInstallFault.busy }
            running = true
        }
        defer { busy.withLock { $0 = false } }
        return try await work()
    }

    /// Runs one write (or request/reply) with an independent WATCHDOG. A blocked L2CAP write cannot be unstuck by
    /// task cancellation (`L2CAPPipe` has no write deadline), so the watchdog force-closes the transport after
    /// `limit`; the stuck writer then resumes with `.linkLost` and `work` throws. Every firmware write — INSTALL,
    /// svc28 start/stop, Airship frames, withdrawal and channel close — goes through this.
    static func watched<T>(_ limit: Duration, _ what: String, close: @escaping @Sendable () -> Void,
                           _ work: () async throws -> T) async throws -> T {
        let watchdog = Task.detached {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            kitLog("firmware", "watchdog fired during \(what); closing the transport to unblock it")
            close()
        }
        defer { watchdog.cancel() }
        return try await work()
    }

    /// Whether `error` is the link going away (a transport loss or the attempt no longer current) rather than the
    /// device or the protocol saying no.
    static func isLinkLoss(_ error: Error) -> Bool {
        if case ReGlassError.linkLost = error { return true }
        if case WakeWordFault.connectionChanged = error { return true }
        return false
    }
}
