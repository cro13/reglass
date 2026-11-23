import Foundation

/// Installs a wake word set on the glasses, on a dedicated link. The app lets go of its live
/// connection first (the glasses take one session at a time) and reconnects after.
///
/// Order of operations (do not reorder): check the set's files → connect with the saved owner key (READY, trust
/// both ways, serial, an Audio firmware build equal to the set's) → read the installed resources and refuse anything unrecognised → start
/// the glasses' resource OTA application (svc28) → the install request, every file the glasses ask for, the
/// completion, ENABLE (svc29 + svc20) → stop the OTA application → read the resources back. The install counts
/// only when the readback shows exactly the new artifact and version with the feature enabled.
///
/// Feature replacement on the glasses is not transactional: once files go over, an interrupted install can leave
/// the wake word not working until a complete set is installed again (`ReGlassError.wakeWordNotConfirmed`).
public final class WakeWordInstaller: Sendable {
    private let glassesID: UUID
    private let serial: String
    private let keeper = ConnectionKeeper()

    /// Throws `.keyUnavailable` before the first unlock, `.noSavedIdentity`, `.keyRefused` or
    /// `.verificationIncomplete` as the live connection does.
    public init(glasses: SavedGlasses) throws {
        guard try IdentityStore.ownerKey() != nil,
              let record = try IdentityStore.record(serial: glasses.serial) else { throw ReGlassError.noSavedIdentity }
        switch record.state {
        case .verified: break
        case .refused: throw ReGlassError.keyRefused
        case .pending, .unverified: throw ReGlassError.verificationIncomplete
        }
        glassesID = record.glassesID
        serial = record.serial
    }

    /// Installs the set `library` keeps for `wakeWord` and returns what the glasses report afterwards (`.custom` or
    /// `.heyMeta`). Throws a `ReGlassError`: `.wakeWordFilesDamaged` when the kept set is missing or fails its
    /// checks (nothing sent), `.wakeWordNotConfirmed` once files may have changed.
    public func install(_ wakeWord: WakeWord, from library: WakeWordLibrary,
                        progress: @escaping @Sendable (WakeWordProgress) -> Void) async throws -> InstalledWakeWord {
        let name = wakeWord.logName
        let changing = Locked(false)
        do {
            let loaded = try library.set(for: wakeWord).load()
            kitLog("wakeword", "\(name): \(loaded.files.count) files checked (\(loaded.set.totalBytes) bytes)")
            guard let key = try IdentityStore.ownerKey() else { throw ReGlassError.noSavedIdentity }
            // Remembered before anything is sent, so the set stays recognised on the glasses even if its files
            // are removed from this iPhone after an interrupted install.
            if wakeWord == .custom { library.noteInstalling(loaded.set) }
            progress(.connecting)
            keeper.hold(glassesID)
            let link = WakeWordLink(glasses: glassesID, serial: serial, key: key)
            await link.start()
            let result: InstalledWakeWord
            do {
                result = try await run(wakeWord, loaded: loaded, link: link, changing: changing, progress: progress)
            } catch {
                await link.stop()
                keeper.release()
                throw error
            }
            await link.stop()
            keeper.release()
            kitLog("wakeword", "\(name) installed and confirmed")
            return result
        } catch {
            let mapped = WakeWordFault.reglassError(error, changing: changing.current)
            kitLog("wakeword", "\(name) stopped: \(Self.describe(error))" + (changing.current ? " (after files may have changed)" : ""))
            throw mapped
        }
    }

    private func run(_ wakeWord: WakeWord, loaded: WakeWordSet.Loaded, link: WakeWordLink, changing: Locked<Bool>,
                     progress: @escaping @Sendable (WakeWordProgress) -> Void) async throws -> InstalledWakeWord {
        let name = wakeWord.logName
        let ready = try await link.waitUntilUsable(timeout: Self.connectLimit)
        // A set goes only to glasses on the firmware it's made for (checked before anything is sent).
        let glassesBuild = link.peerInfo(for: ready).flatMap { WakeWordCatalog.firmwareVersion(fromBuild: $0.firmware) }
        guard let glassesBuild, glassesBuild == loaded.set.firmware else {
            kitLog("wakeword", "set made for \(loaded.set.firmware), glasses run \(glassesBuild ?? "unknown"); nothing sent")
            throw WakeWordFault.setForOtherFirmware(set: loaded.set.firmware, glasses: glassesBuild ?? "an unknown build")
        }

        let before = try await link.readInventory(ready)
        // Install only over recognised resources or into an empty resource store.
        let known = WakeWordCatalog.known(before)
        if let known {
            kitLog("wakeword", "installed before: \(known.family) \(known.version), "
                     + "\(known.enabled ? "enabled" : "not enabled"), bootPlaceholder: \(known.bootPlaceholderInstalled)")
        } else if WakeWordCatalog.isEmpty(before) {
            kitLog("wakeword", "installed before: nothing (no artifacts, no features); installing into an empty store")
        } else {
            kitLog("wakeword", "installed resources not recognised; nothing sent")
            throw WakeWordFault.unrecognisedResources
        }
        // The glasses skip any file whose stored version matches the request, a half-written one included, and
        // Hey Meta always uses Meta's fixed version. So with that version already recorded (an interrupted
        // restore), a second restore could confirm a truncated model. A custom set's fresh version rewrites all files.
        if wakeWord == .heyMeta, known?.family == .factory {
            kitLog("wakeword", "factory version already recorded; restore refused, nothing sent")
            throw WakeWordFault.restoreNeedsFreshSet
        }
        let version = try loaded.set.deploymentVersion(current: known?.version)
        kitLog("wakeword", "\(name): installing as \(version)")

        let transfer = WakeWordTransfer(mux: ready.mux, loaded: loaded, version: version,
                                        // Both sets: the wake model must actually go over, or nothing that
                                        // matters changed and ENABLE would confirm the old (or partial) file.
                                        requireWakeTransfer: true,
                                        isCurrent: link.currentCheck(ready.generation), progress: progress)
        link.attach(transfer)
        defer { link.attach(nil) }
        progress(.sending(0))
        try await link.withOtaApplication(ready) {
            do {
                try await transfer.run()
            } catch {
                if await transfer.requested { changing.withLock { $0 = true } }
                throw error
            }
            changing.withLock { $0 = true }
        }

        progress(.finishing)
        let after = try await link.readInventory(ready)
        guard WakeWordCatalog.confirms(after, artifact: loaded.set.artifact, version: version) else {
            kitLog("wakeword", "readback: \(WakeWordCatalog.classify(after)), not the new set enabled")
            throw WakeWordFault.readbackMismatch
        }
        kitLog("wakeword", "readback: \(version) installed, feature enabled")
        return WakeWordCatalog.classify(after)
    }

    private static func describe(_ error: Error) -> String {
        if let fault = error as? WakeWordFault { return fault.description }
        return String(describing: ReGlassError.from(error))
    }

    /// READY, trust, serial and firmware within 60 s, as setup's verification allows.
    private static let connectLimit: Duration = .seconds(60)
}
