import Foundation

/// After the transfer link closes for reboot, reconnects and compares the running MCU build in tag 1 of svc100
/// message 3 with the target.
///
/// Each attempt accepts any well-formed orca build and reads device info from that attempt's ready link.
/// An unchanged build or connection error may mean the reboot is still underway, so both get a bounded retry.
struct FirmwareConfirmation {
    /// What the glasses came up on, compared to the install target.
    enum Result: Equatable, Sendable {
        /// The glasses report `version`, the target build.
        case matched(version: String)
        /// The LAST attempt read the build the glasses had before the install (not rebooted into the target).
        case unchanged(version: String)
        /// An earlier attempt read the previous build, but the later attempts could not read anything: the current
        /// build is unknown, not definitely unchanged.
        case unconfirmed(lastSeen: String)
        /// The glasses report a third build — neither the previous one nor the target.
        case mismatch(version: String)
    }

    let glassesID: UUID
    let serial: String
    let key: OwnerKey
    let target: String
    /// The build the glasses reported on the transfer link, before the install (nil when it was unreadable).
    let previous: String?

    /// Reconnects and reads the svc100 build, comparing it to `target`. Each attempt is a fresh owner-key link given
    /// `perAttempt` to come up; between attempts it waits `pause` (the glasses may still be rebooting or applying).
    /// Throws only when no attempt ever read a build.
    func confirm(attempts: Int = 3, perAttempt: Duration = .seconds(90),
                 pause: Duration = .seconds(20)) async throws -> Result {
        let attempts = max(1, attempts)
        var lastError: Error?
        var lastUnchanged: String?
        var lastAttemptReadUnchanged = false
        for attempt in 1...attempts {
            if attempt > 1 { try await Task.sleep(for: pause) }
            do {
                let version = try await readBuildOnce(perAttempt: perAttempt)
                kitLog("firmware", "post-reboot build: \(version), target \(target), previous \(previous ?? "unknown") "
                       + "[attempt \(attempt)/\(attempts)]")
                if version == target { return .matched(version: version) }
                if let previous, version == previous {
                    lastUnchanged = version
                    lastAttemptReadUnchanged = true
                    continue                                    // not rebooted into the new build (yet): retry
                }
                return .mismatch(version: version)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                lastAttemptReadUnchanged = false
                kitLog("firmware", "post-reboot confirm attempt \(attempt)/\(attempts) failed: \(describe(error))")
            }
        }
        if let lastUnchanged {
            return lastAttemptReadUnchanged ? .unchanged(version: lastUnchanged) : .unconfirmed(lastSeen: lastUnchanged)
        }
        throw lastError ?? ReGlassError.noAnswer
    }

    /// One attempt: a fresh owner-key link whose firmware policy accepts ANY well-formed orca build, then read the
    /// real version from that attempt's svc100 answer.
    private func readBuildOnce(perAttempt: Duration) async throws -> String {
        let link = WakeWordLink(
            glasses: glassesID, serial: serial, key: key,
            firmwareAccepts: { build in build.flatMap(WakeWordCatalog.firmwareVersion(fromBuild:)) != nil })
        await link.start()
        do {
            let ready = try await link.waitUntilUsable(timeout: perAttempt)
            guard let info = link.peerInfo(for: ready),
                  let version = WakeWordCatalog.firmwareVersion(fromBuild: info.firmware) else {
                throw WakeWordFault.malformed("the glasses did not report a readable firmware build")
            }
            await link.stop()
            return version
        } catch {
            await link.stop()
            throw error
        }
    }

    private func describe(_ error: Error) -> String {
        if let fault = error as? WakeWordFault { return fault.description }
        return String(describing: ReGlassError.from(error))
    }
}
