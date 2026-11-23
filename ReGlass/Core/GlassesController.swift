import Foundation
import ReGlassKit
import SwiftUI
import UIKit
import UserNotifications

/// The one app-wide model: which glasses ReGlass owns, their live status, the Meta sign-in, and setup hand-offs.
@MainActor
final class GlassesController: ObservableObject {
    static let shared = GlassesController()

    let log: ActivityLog
    let account: MetaAccount
    /// The wake word sets the wearer imported (Application Support/ReGlass/WakeWord). Made here, at launch, so the
    /// first read of the glasses already recognises them.
    let wakeWordLibrary = WakeWordLibrary(directory: Storage.directory.appendingPathComponent("WakeWord", isDirectory: true))

    @Published private(set) var paired: PairedGlasses?
    @Published private(set) var live = GlassesLive()
    @Published private(set) var accountStatus: MetaAccount.Status
    /// The Meta sign-in conversation on screen, if any. Shown inline on the onboarding's sign-in page.
    @Published private(set) var signIn: SignInFlow?
    /// The wake word on the glasses, and any read or install in progress.
    @Published private(set) var wakeWord = WakeWordState()
    /// The glasses' firmware: what Meta offers, a running update and its outcome.
    @Published private(set) var firmwareUpdate = FirmwareUpdateState()
    /// The offered version whose home banner the wearer put away ("Later"); a newer version shows again.
    @Published private(set) var firmwareBannerHiddenVersion = UserDefaults.standard.string(forKey: GlassesController.firmwareBannerHiddenKey)
    /// True once the glasses have sat in the case below 80 % for 60 s without charging.
    @Published private(set) var notChargingInCase = false
    /// Adaptive Volume on the glasses (svc31 tag 80, 0 or 1, default 1).
    @Published var adaptiveVolume: Bool {
        didSet {
            guard adaptiveVolume != oldValue, !suppressAudioDidSet else { return }
            UserDefaults.standard.set(adaptiveVolume, forKey: Self.adaptiveVolumeKey)
            UserDefaults.standard.set(true, forKey: Self.audioCustomizedKey)
            applyAudioSettings(GlassesAudioSettings(adaptiveVolume: adaptiveVolume))
        }
    }
    /// Head-tracked Spatial Audio on the glasses (svc31 tag 286, 0 or 4, default 4).
    @Published var spatialAudio: Bool {
        didSet {
            guard spatialAudio != oldValue, !suppressAudioDidSet else { return }
            UserDefaults.standard.set(spatialAudio, forKey: Self.spatialAudioKey)
            UserDefaults.standard.set(true, forKey: Self.audioCustomizedKey)
            applyAudioSettings(GlassesAudioSettings(spatialAudio: spatialAudio))
        }
    }
    /// "Hey Meta" listening on the glasses (svc31 tag 36, 0 or 1). ReGlass enables it by default.
    @Published var heyMetaEnabled: Bool {
        didSet {
            guard heyMetaEnabled != oldValue, !suppressAudioDidSet else { return }
            UserDefaults.standard.set(heyMetaEnabled, forKey: Self.heyMetaEnabledKey)
            applyWakeSettings(reason: "Hey Meta switched \(heyMetaEnabled ? "on" : "off")")
        }
    }
    /// The setup flow is on screen for glasses that are already set up (Reconnect / Set up again).
    @Published var showingSetup = false
    @Published var stayConnected: Bool {
        didSet {
            UserDefaults.standard.set(stayConnected, forKey: "reglass.stayConnected")
            if stayConnected { connect() } else { disconnect() }
        }
    }

    private static let adaptiveVolumeKey = "reglass.audio.adaptiveVolume"
    private static let spatialAudioKey = "reglass.audio.spatialAudio"
    private static let audioCustomizedKey = "reglass.audio.customized"
    private static let heyMetaEnabledKey = "reglass.wakeWord.heyMetaEnabled"
    /// The serial of the glasses that received the assistant and wake word settings.
    private static let wakeSettingsAppliedKey = "reglass.wakeWord.settingsAppliedSerial"
    nonisolated static let caseNotChargingNotificationID = "reglass.case.notCharging"
    private static let caseNotChargingWait: Duration = .seconds(60)

    private var connection: GlassesConnection?
    private var updatesTask: Task<Void, Never>?
    /// The previous connection while it closes. The glasses take one session at a time, so nothing new starts first.
    private var stopping: Task<Void, Never>?
    private var stopGeneration = 0
    private var setupActive = false
    /// A wake word install holds the glasses: the live connection stays down until it ends.
    private var wakeWordInstallActive = false
    /// The running firmware update (`startFirmwareUpdate`), so Stop and leaving the screen can cancel it.
    private var firmwareTask: Task<Void, Never>?
    /// Set once the installer reports `.applying` (the COMPLETE write started): from then on the glasses decide the
    /// outcome, and nothing in the app may stop the update — not Stop, not leaving the screen.
    private var firmwareApplyStarted = false
    /// Why a running update was cancelled, for its outcome.
    private var firmwareStopReason: String?
    /// The grace timer while ReGlass is off screen before the install.
    private var firmwareAwayTask: Task<Void, Never>?
    /// Checks for firmware updates every `firmwareCheckInterval`.
    private var firmwareCheckLoop: Task<Void, Never>?
    /// The version an update ended "unconfirmed" on: once the glasses report it, the update is confirmed.
    private var firmwareAwaitingVersion: String?
    /// Read once per live link, even when the connection object reconnects.
    private var wakeWordReadFrom: ObjectIdentifier?
    private var wakeWordReadGeneration = 0
    private var wakeWordBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suppressAudioDidSet = false
    private var caseChargeWatchTask: Task<Void, Never>?
    private var caseChargeAlerted = false

    init() {
        let log = ActivityLog()
        self.log = log
        ReGlassKitLog.setSink { line in log.add(line) }
        #if DEBUG
        let debugFlags = CommandLine.arguments.filter { $0.hasPrefix("-ReGlass") }
        if !debugFlags.isEmpty { log.add("DEBUG launch flags: \(debugFlags.joined(separator: " "))") }
        #endif
        account = MetaAccount(storageDirectory: Storage.directory)
        accountStatus = account.status
        paired = PairedGlasses.load()
        adaptiveVolume = UserDefaults.standard.object(forKey: Self.adaptiveVolumeKey) as? Bool ?? true
        spatialAudio = UserDefaults.standard.object(forKey: Self.spatialAudioKey) as? Bool ?? true
        heyMetaEnabled = UserDefaults.standard.object(forKey: Self.heyMetaEnabledKey) as? Bool ?? true
        stayConnected = UserDefaults.standard.object(forKey: "reglass.stayConnected") as? Bool ?? true
        if let paired {
            live.battery = paired.lastBattery
            live.caseBattery = paired.lastCaseBattery
            live.caseSeenAt = paired.lastCaseSeenAt
            live.firmware = paired.firmware
            live.model = paired.model
            live.serial = paired.serial
            live.updatedAt = paired.lastSeen
        }
        // A firmware update needs ReGlass on screen until the glasses install it (iOS suspends a backgrounded app).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.firmwareLeftScreen() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.firmwareBackOnScreen()
                self?.checkFirmwareIfDue()
            }
        }
        // Check for firmware updates periodically while ReGlass runs.
        firmwareCheckLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.firmwareCheckInterval))
                self?.checkFirmwareIfDue()
            }
        }
        let updates = account.statusUpdates()
        Task { [weak self] in
            for await status in updates {
                guard let self else { return }
                accountStatus = status
                // The conversation is over (signed in, failed, or cancelled): take the form down.
                if status != .signingIn { signIn = nil }
            }
        }
        log.add("ReGlass started")
    }

    // MARK: Lifecycle

    /// At launch and on every return to the foreground.
    func connectIfReady() {
        guard paired != nil, stayConnected, !setupActive, !showingSetup, !wakeWordInstallActive else { return }
        connect()
    }

    func sceneBecameActive() {
        connectIfReady()
        connection?.refresh()
    }

    // MARK: Live connection

    func connect() {
        guard connection == nil, let paired, stayConnected, !setupActive, !wakeWordInstallActive else { return }
        if let stopping {
            // The last connection is still letting go; connect once it has.
            Task { [weak self] in
                await stopping.value
                self?.connect()
            }
            return
        }
        let made: GlassesConnection
        do {
            guard let saved = try GlassesVault.savedGlasses().first(where: { $0.serial == paired.serial }) else {
                throw ReGlassError.noSavedIdentity
            }
            made = try GlassesConnection(glasses: saved)
        } catch ReGlassError.keyUnavailable {
            live.connection = .keyUnavailable
            log.add("Saved key locked until this iPhone is unlocked; no key changed")
            return
        } catch {
            live.connection = .refused
            log.add("These glasses need to be reconnected or set up again (\(String(describing: error)))")
            return
        }
        GlassesBluetooth.start()
        connection = made
        live.connection = .connecting
        let updates = made.updates()
        updatesTask = Task { [weak self] in
            for await status in updates { self?.apply(status) }
            // The stream ends when the connection stops: by itself (refusal) or because ReGlass stopped it.
            guard let self, self.connection === made else { return }
            self.connection = nil
            self.updatesTask = nil
        }
        made.start()
        // The assistant rides on this connection: it answers the glasses' wake words while the link is up.
        AssistantController.shared.connect(link: made.assistant)
        TimerService.shared.attach(made)
        TapToStop.shared.attach(made)   // tap to stop: the glasses' touches (ReGlass/TapToStop/)
    }

    func disconnect() {
        releaseConnection()
        if !live.connection.needsAttention { live.connection = .idle }
    }

    /// A fresh status snapshot, or a reconnect if the link is down.
    func refresh() {
        if let connection { connection.refresh() } else { connectIfReady() }
    }

    /// Lets go of the live connection; the returned task ends once the glasses are free.
    @discardableResult
    private func releaseConnection() -> Task<Void, Never>? {
        guard let connection else { return stopping }
        self.connection = nil
        invalidateWakeWordRead()
        AssistantController.shared.disconnect()
        TimerService.shared.detach()
        updatesTask?.cancel()
        updatesTask = nil
        let previous = stopping
        stopGeneration += 1
        let generation = stopGeneration
        let task = Task { [weak self] in
            await previous?.value
            await connection.stop()
            guard let self, self.stopGeneration == generation else { return }
            self.stopping = nil
        }
        stopping = task
        return task
    }

    private func apply(_ status: GlassesStatus) {
        let wasConnected = live.connection.isConnected
        var next = live
        next.connection = GlassesLive.Connection(status.connection)
        next.battery = status.battery ?? next.battery
        next.charging = status.charging
        next.caseBattery = status.caseBattery ?? next.caseBattery
        next.caseCharging = status.caseCharging
        next.inCase = status.inCase ?? next.inCase
        if next.caseIsLive, next.caseBattery != nil { next.caseSeenAt = Date() }
        next.worn = status.worn ?? next.worn
        next.firmware = status.firmware ?? next.firmware
        next.model = status.model ?? next.model
        next.serial = status.serial ?? next.serial
        if next.connection == .connected { next.updatedAt = Date() }
        if next.connection == .refused && live.connection != .refused {
            log.add("The glasses turned ReGlass's key down; stopped reconnecting")
        }
        if wasConnected, !next.connection.isConnected { invalidateWakeWordRead() }
        if next != live { live = next }
        confirmFirmwareFromLive()
        checkCaseCharging(next)
        remember(next)
        if !wasConnected, next.connection.isConnected {
            readWakeWord()
            checkFirmwareIfDue()
            if UserDefaults.standard.bool(forKey: Self.audioCustomizedKey) {
                applyAudioSettings(GlassesAudioSettings(adaptiveVolume: adaptiveVolume, spatialAudio: spatialAudio))
            }
            // Enable the assistant and apply the wearer's "Hey Meta" preference once per pair. A factory reset
            // clears both settings, and the glasses listen for the wake word only when both are enabled.
            if let serial = paired?.serial, UserDefaults.standard.string(forKey: Self.wakeSettingsAppliedKey) != serial {
                applyWakeSettings(reason: "first connection of these glasses")
            }
        }
    }

    /// Keeps the last readings for the next launch (at most once a minute when only the time moved).
    private func remember(_ live: GlassesLive) {
        guard var record = paired else { return }
        let before = record
        record.lastBattery = live.battery ?? record.lastBattery
        record.lastCaseBattery = live.caseBattery ?? record.lastCaseBattery
        record.lastCaseSeenAt = live.caseSeenAt ?? record.lastCaseSeenAt
        record.firmware = live.firmware ?? record.firmware
        record.model = live.model ?? record.model
        if live.connection == .connected { record.lastSeen = Date() }
        if record == before { return }
        var a = before, b = record
        a.lastSeen = nil
        b.lastSeen = nil
        a.lastCaseSeenAt = nil
        b.lastCaseSeenAt = nil
        if a == b, let previous = before.lastSeen, let now = record.lastSeen, now.timeIntervalSince(previous) < 60 { return }
        paired = record
        record.save()
    }

    // MARK: Setup hand-off

    /// Before setup touches the glasses, the live connection lets go.
    func beginSetup() async {
        setupActive = true
        await releaseConnection()?.value
        live.connection = .idle
    }

    /// Setup ended without success.
    func cancelSetup() {
        setupActive = false
    }

    /// Setup verified the glasses: remember them and connect.
    func completeSetup(found: FoundGlasses, result: GlassesSetupResult) {
        setupActive = false
        // Same glasses set up again: keep the wearer's name and the original setup date.
        let previous = paired.flatMap { $0.serial == result.serial ? $0 : nil }
        let record = PairedGlasses(
            id: found.id,
            serial: result.serial,
            name: previous?.name ?? found.name,
            model: result.model ?? previous?.model,
            firmware: result.firmware ?? previous?.firmware,
            setUpAt: previous?.setUpAt ?? Date(),
            lastBattery: result.batteryPercent,
            lastCaseBattery: previous?.lastCaseBattery,
            lastSeen: Date()
        )
        record.save()
        if previous == nil { wakeWord = WakeWordState() }
        wakeWordReadFrom = nil
        paired = record
        live = GlassesLive(connection: .idle, battery: result.batteryPercent, firmware: record.firmware,
                           model: record.model, serial: record.serial, updatedAt: Date())
        log.add("Setup complete; ReGlass owns these glasses")
        showingSetup = false
        connectIfReady()
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var record = paired, !trimmed.isEmpty else { return }
        record.name = String(trimmed.prefix(40))
        record.save()
        paired = record
    }

    /// Forgets the glasses. ReGlass's owner key stays sealed on this iPhone so a later setup reuses it.
    func forget() {
        disconnect()
        if let paired {
            do {
                try GlassesVault.forget(serial: paired.serial)
            } catch {
                log.add("Forget: the saved identity couldn't be updated (unlock the iPhone); record removed anyway")
            }
        }
        PairedGlasses.clear()
        paired = nil
        live = GlassesLive()
        wakeWord = WakeWordState()
        wakeWordReadFrom = nil
        log.add("Forgot the glasses; the owner key stays on this iPhone for a later setup")
    }

    // MARK: Wake word

    /// True while nothing else holds the glasses and the live link is up: a wake word read or install may start.
    var canChangeWakeWord: Bool {
        paired != nil && live.connection.isConnected && !wakeWord.isBusy && !wakeWord.unavailable
            && !setupActive && !showingSetup
    }

    private func invalidateWakeWordRead() {
        wakeWordReadGeneration += 1
        wakeWordReadFrom = nil
        wakeWord.installed = nil
        wakeWord.isReading = false
        wakeWord.readProblem = nil
        wakeWord.unavailable = false
        if case .installed = wakeWord.activity { wakeWord.activity = .idle }
    }

    /// Reads stored wake word metadata over the live link. It does not identify the running DSP model.
    func readWakeWord(force: Bool = false) {
        guard let connection, live.connection.isConnected, !wakeWord.isBusy else { return }
        let source = ObjectIdentifier(connection)
        if !force, wakeWordReadFrom == source { return }
        wakeWordReadFrom = source
        let generation = wakeWordReadGeneration
        wakeWord.readProblem = nil
        wakeWord.isReading = true
        Task { [weak self] in
            var problem: String?
            var unavailable = false
            var installed: InstalledWakeWord?
            do {
                installed = try await connection.readWakeWord()
            } catch ReGlassError.wakeWordUnavailable {
                unavailable = true
            } catch {
                problem = (error as? ReGlassError)?.errorDescription ?? "ReGlass couldn't check your glasses."
            }
            guard let self, self.connection === connection, wakeWordReadGeneration == generation else { return }
            if let installed {
                wakeWord.installed = installed
                // An install that couldn't be confirmed but did take: the glasses now say so.
                if case .failed(let choice, _) = wakeWord.activity, wakeWord.isCurrent(choice) { wakeWord.activity = .idle }
            }
            wakeWord.unavailable = unavailable
            wakeWord.readProblem = problem
            if problem != nil, wakeWordReadFrom == source { wakeWordReadFrom = nil }
            wakeWord.isReading = false
        }
    }

    /// Installs `choice` on the glasses. The live connection lets go first and comes back after.
    func installWakeWord(_ choice: WakeWord) {
        guard let paired, live.connection.isConnected, !wakeWord.isBusy, !wakeWord.unavailable,
              !setupActive, !showingSetup else { return }
        wakeWordInstallActive = true
        wakeWord.readProblem = nil
        wakeWord.activity = .installing(choice, .connecting)
        beginWakeWordBackgroundTime()
        log.add("Wake word: installing \(choice.title)")
        let serial = paired.serial
        Task { [weak self] in
            guard let self else { return }
            await releaseConnection()?.value
            live.connection = .connecting
            let outcome: Result<InstalledWakeWord, Error>
            do {
                guard let saved = try GlassesVault.savedGlasses().first(where: { $0.serial == serial }) else {
                    throw ReGlassError.noSavedIdentity
                }
                let installer = try WakeWordInstaller(glasses: saved)
                outcome = .success(try await installer.install(choice, from: wakeWordLibrary) { [weak self] progress in
                    Task { @MainActor in self?.wakeWordProgressed(choice, progress) }
                })
            } catch {
                outcome = .failure(error)
            }
            finishWakeWordInstall(choice, outcome)
        }
    }

    /// Clears a finished install's message.
    func dismissWakeWordOutcome() {
        switch wakeWord.activity {
        case .installed, .failed: wakeWord.activity = .idle
        default: break
        }
    }

    private func wakeWordProgressed(_ choice: WakeWord, _ progress: WakeWordProgress) {
        guard case .installing(let current, let previous) = wakeWord.activity, current == choice else { return }
        // Progress hops here in its own task; never let a late report move the bar back.
        if case .sending(let new) = progress, case .sending(let old) = previous, new < old { return }
        if case .sending = progress, case .finishing = previous { return }
        wakeWord.activity = .installing(choice, progress)
        if progress != .connecting, live.connection == .connecting { live.connection = .connected }
    }

    private func finishWakeWordInstall(_ choice: WakeWord, _ outcome: Result<InstalledWakeWord, Error>) {
        switch outcome {
        case .success(let installed):
            wakeWord.installed = installed
            wakeWord.activity = .installed(choice)
            log.add("Wake word: \(choice.title) installed and confirmed by the glasses")
            // A model alone doesn't make the glasses listen: write the assistant and wake word switches again on
            // the next connection (this one is closing for the install).
            UserDefaults.standard.removeObject(forKey: Self.wakeSettingsAppliedKey)
            if choice == .heyMeta, !heyMetaEnabled {
                // Restoring Hey Meta means wanting it: switch it on without writing now (the link is closing).
                suppressAudioDidSet = true
                heyMetaEnabled = true
                suppressAudioDidSet = false
                UserDefaults.standard.set(true, forKey: Self.heyMetaEnabledKey)
            }
        case .failure(let error):
            let kitError = error as? ReGlassError
            if kitError == .wakeWordNotConfirmed {
                // Files may have changed: what the glasses use now is only known after a fresh read.
                wakeWord.installed = nil
            }
            let message = kitError?.errorDescription ?? "The wake word didn't change."
            wakeWord.activity = .failed(choice, message)
            log.add("Wake word: \(choice.title) didn't finish (\(kitError.map { String(describing: $0) } ?? "error"))")
        }
        // Read the stored resources again on the next connection.
        wakeWordReadFrom = nil
        wakeWordInstallActive = false
        endWakeWordBackgroundTime()
        live.connection = .idle
        connectIfReady()
    }

    /// An install takes about a minute: keep the screen on and ask iOS for time if ReGlass goes to the background.
    private func beginWakeWordBackgroundTime() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard wakeWordBackgroundTask == .invalid else { return }
        wakeWordBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Glasses install") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTimeExpiring() }
        }
    }

    /// iOS is about to suspend ReGlass. A firmware update that hasn't reached the install stops here (normally the
    /// 20 s grace timer stopped it already); then the background time ends.
    private func backgroundTimeExpiring() {
        if firmwareUpdate.isRunning, !firmwareApplyStarted {
            firmwareStopReason = "iOS paused ReGlass in the background."
            firmwareTask?.cancel()
        }
        endWakeWordBackgroundTime()
    }

    private func endWakeWordBackgroundTime() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard wakeWordBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(wakeWordBackgroundTask)
        wakeWordBackgroundTask = .invalid
    }

    // MARK: Firmware update

    nonisolated static let firmwareAwayNotificationID = "reglass.firmware.away"
    static let firmwareModelNote = "ReGlass updates only the Ray-Ban Meta Clubmaster (Audio) glasses it was tested "
        + "with. Update other glasses in the Meta AI app."

    /// The build number the glasses run, from their last report ("1082194281").
    var currentFirmwareVersion: String? {
        (live.firmware ?? paired?.firmware).flatMap(FirmwareOtaInstaller.version(fromBuild:))
    }

    /// Why an update can't start right now, in the wearer's words; nil when it can. The battery floor is checked
    /// again by the installer on its own link (the glasses' own report), so a missing reading here does not block.
    var firmwareUpdateBlocker: String? {
        guard paired != nil else { return "Set up your glasses first." }
        guard live.connection.isConnected else { return "Connect your glasses first." }
        guard currentFirmwareVersion != nil else { return Self.firmwareModelNote }
        if wakeWordInstallActive || wakeWord.isBusy { return "Wait for the wake word install to finish." }
        let floor = FirmwareOtaInstaller.minimumBatteryPercent
        if let battery = live.battery, battery < floor {
            return "Your glasses are at \(battery) %. Charge them to at least \(floor) % first."
        }
        return nil
    }

    private static let firmwareCheckedAtKey = "reglass.firmware.checkedAt"
    private static let firmwareNotifiedKey = "reglass.firmware.notifiedVersion"
    nonisolated static let firmwareBannerHiddenKey = "reglass.firmware.bannerHiddenVersion"
    nonisolated static let firmwareAvailableNotificationID = "reglass.firmware.available"
    /// Minimum interval between background firmware update checks.
    private static let firmwareCheckInterval: TimeInterval = 6 * 3600

    /// The update Meta offers, if the last check found one.
    var firmwareOffer: FirmwareAvailableUpdate? {
        if case .available(let update) = firmwareUpdate.check { return update }
        return nil
    }

    /// Whether the home shows the update banner: an update is offered, nothing is running, and the wearer didn't put
    /// this version away.
    var showsFirmwareBanner: Bool {
        guard let offer = firmwareOffer, !firmwareUpdate.isRunning, !offer.powerwash else { return false }
        return firmwareBannerHiddenVersion != offer.targetVersion
    }

    /// "Later" on the home banner: hides it until Meta offers a newer version.
    func hideFirmwareBanner() {
        guard let offer = firmwareOffer else { return }
        firmwareBannerHiddenVersion = offer.targetVersion
        UserDefaults.standard.set(offer.targetVersion, forKey: Self.firmwareBannerHiddenKey)
    }

    /// Checks for updates on connection and periodically, up to once per `firmwareCheckInterval`.
    /// Requires paired glasses, a known firmware build, and a Meta sign-in. Failures are logged without
    /// replacing the page's last result.
    private func checkFirmwareIfDue() {
        guard paired != nil, accountStatus == .signedIn, !firmwareUpdate.isRunning,
              currentFirmwareVersion != nil else { return }
        if case .checking = firmwareUpdate.check { return }
        let last = UserDefaults.standard.object(forKey: Self.firmwareCheckedAtKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.firmwareCheckInterval else { return }
        checkFirmwareUpdate(background: true)
    }

    /// Asks Meta's update server what it offers these glasses. Never touches the glasses. A background check offers
    /// a new version with a notification, once per version; the Firmware page and the home banner show it too.
    func checkFirmwareUpdate(background: Bool = false) {
        guard let paired, !firmwareUpdate.isRunning else { return }
        if case .checking = firmwareUpdate.check { return }
        // Only the Audio glasses (an orca build) are updated: other models may update over Wi-Fi or other paths
        // ReGlass doesn't handle, and an orca offer must never reach them.
        guard currentFirmwareVersion != nil else {
            if !background { firmwareUpdate.check = .failed(Self.firmwareModelNote) }
            return
        }
        let before = firmwareUpdate.check
        firmwareUpdate.check = .checking
        let serial = paired.serial
        let account = self.account
        Task { [weak self] in
            do {
                let update = try await FirmwareOtaInstaller.availableUpdate(account: account, serial: serial)
                guard let self else { return }
                UserDefaults.standard.set(Date(), forKey: Self.firmwareCheckedAtKey)
                let current = self.currentFirmwareVersion
                let available = current != update.targetVersion
                self.firmwareUpdate.check = available ? .available(update) : .upToDate(update.targetVersion)
                self.log.add("Firmware: Meta offers \(update.targetVersion) (\(FirmwareUpdateState.size(update.bytes))); "
                    + "the glasses run \(current ?? "an unknown build")\(background ? " [background check]" : "")")
                if available, !update.powerwash,
                   UserDefaults.standard.string(forKey: Self.firmwareNotifiedKey) != update.targetVersion {
                    UserDefaults.standard.set(update.targetVersion, forKey: Self.firmwareNotifiedKey)
                    await self.postFirmwareAvailableNotification(update)
                }
            } catch {
                guard let self else { return }
                self.log.add("Firmware: update check failed (\(String(describing: error)))"
                    + (background ? " [background check]" : ""))
                if background {
                    self.firmwareUpdate.check = before
                } else {
                    let detail = (error as? ReGlassError)?.errorDescription
                        ?? "ReGlass couldn't reach Meta's update service."
                    self.firmwareUpdate.check = .failed(detail)
                }
            }
        }
    }

    private func postFirmwareAvailableNotification(_ update: FirmwareAvailableUpdate) async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = "Update for your glasses"
        content.body = "Version \(update.targetVersion) is ready. Open ReGlass to install it; it takes "
            + "\(FirmwareUpdateState.estimate(bytes: update.bytes))."
        content.sound = .default
        content.threadIdentifier = "reglass.glasses"
        let request = UNNotificationRequest(identifier: Self.firmwareAvailableNotificationID, content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Updates the glasses to the version the wearer confirmed on the Firmware page. A `rehearsal` (DEBUG builds
    /// only) sends the whole update and stops before installation. The screen stays on throughout the update, and
    /// leaving ReGlass before installation starts a 20 s grace period.
    func startFirmwareUpdate(expectedTarget: String, rehearsal: Bool) {
        #if !DEBUG
        guard !rehearsal else { return }
        #endif
        guard !firmwareUpdate.isRunning, firmwareUpdateBlocker == nil, let paired, !setupActive, !showingSetup,
              let update = firmwareOffer, update.targetVersion == expectedTarget, !update.powerwash else { return }
        wakeWordInstallActive = true
        firmwareApplyStarted = false
        firmwareStopReason = nil
        firmwareUpdate.outcome = nil
        firmwareUpdate.run = FirmwareUpdateState.Run(rehearsal: rehearsal, target: update.targetVersion,
                                                     bytes: update.bytes, battery: live.battery)
        // The screen stays on by itself for the whole update, and iOS gives background time for the grace period.
        beginWakeWordBackgroundTime()
        log.add("Firmware: \(rehearsal ? "rehearsal (sends everything, installs nothing)" : "update") to "
            + "\(update.targetVersion) started; battery \(live.battery.map { "\($0) %" } ?? "unknown")")
        let serial = paired.serial
        let account = self.account
        // Built out here, where `self` is still weak: the kit calls these from its own tasks.
        let note: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.log.add("Firmware: \(line)") }
        }
        let progress: @Sendable (FirmwareInstallProgress) -> Void = { [weak self] event in
            Task { @MainActor in self?.firmwareProgressed(event) }
        }
        firmwareTask = Task { [weak self] in
            guard let self else { return }
            await self.releaseConnection()?.value
            self.live.connection = .connecting
            let outcome: FirmwareUpdateState.Outcome
            do {
                guard let saved = try GlassesVault.savedGlasses()
                    .first(where: { $0.serial == serial && $0.isVerified }) else {
                    throw ReGlassError.noSavedIdentity
                }
                let installer = try FirmwareOtaInstaller(glasses: saved)
                // `allowApply` is the irreversible switch: true only for a real update the wearer confirmed.
                let result = try await installer.performRealFirmwareInstall(
                    account: account, expectedTarget: expectedTarget, allowApply: !rehearsal, note: note, progress: progress)
                outcome = .updated(result.confirmedVersion ?? update.targetVersion)
            } catch {
                outcome = self.firmwareOutcome(for: error, rehearsal: rehearsal)
            }
            self.finishFirmwareUpdate(outcome)
        }
    }

    /// Stops a running update — only before the glasses start installing it (then nothing is installed).
    func stopFirmwareUpdate() {
        guard let run = firmwareUpdate.run, run.stage < .installing, !firmwareApplyStarted else { return }
        firmwareStopReason = "You stopped the update."
        log.add("Firmware: stopped by the wearer before the install")
        firmwareTask?.cancel()
    }

    func dismissFirmwareOutcome() {
        firmwareUpdate.outcome = nil
    }

    private func firmwareProgressed(_ event: FirmwareInstallProgress) {
        guard var run = firmwareUpdate.run else { return }
        switch event {
        case .preparing:
            return
        case .transferring(let sent, _):
            // Hops can land out of order: never move back past the install, and never show a rewind as regress.
            guard run.stage <= .sending else { return }
            if run.stage < .sending {
                run.stage = .sending
                run.sendingSince = Date()
                run.sentAtStart = sent
            }
            run.sent = max(run.sent, sent)
        case .applying:
            firmwareApplyStarted = true
            run.stage = .installing
            run.sent = run.bytes
            // From here leaving the screen is harmless: the glasses install on their own.
            if run.away != nil { clearFirmwareAway() }
            run.away = nil
            log.add("Firmware: the glasses have the whole update and are installing it")
        case .confirming:
            run.stage = .confirming
        }
        firmwareUpdate.run = run
    }

    private func firmwareOutcome(for error: Error, rehearsal: Bool) -> FirmwareUpdateState.Outcome {
        let installing = firmwareApplyStarted
        let restartNote = "They install it on their own; check the version once they've restarted."
        if error is CancellationError {
            if installing { return .unconfirmed("Your glasses have the update. " + restartNote) }
            return .stopped((firmwareStopReason ?? "The update stopped.") + " Nothing was installed.")
        }
        if let fault = error as? FirmwareInstallFault {
            switch fault {
            case .applyGateClosed:
                return rehearsal ? .rehearsed : .stopped("The update stopped before installing. Nothing was installed.")
            case .offerChanged(let version):
                let message = "Meta now offers version \(version). Check it and confirm again."
                firmwareUpdate.check = .failed(message)
                return .failed(message)
            case .lowBattery(let percent, let needed):
                return .failed("Your glasses are at \(percent) %. Charge them to at least \(needed) % and try again. "
                    + "Nothing was installed.")
            case .batteryUnknown:
                return .failed("Your glasses didn't report their battery, so ReGlass didn't send the update. "
                    + "Nothing was installed.")
            case .powerwashNotAllowed:
                return .failed("This update would erase your glasses, so ReGlass didn't install it.")
            case .midTransferDrop:
                return .failed("The connection to your glasses dropped while sending. Nothing was installed. "
                    + "Keep them close and try again.")
            case .deviceRefused(let what):
                return installing ? .unconfirmed("Your glasses reported a problem while installing (\(what)). " + restartNote)
                                  : .failed("Your glasses declined the update (\(what)). Nothing was installed.")
            case .applyOutcomeUnknown:
                return .unconfirmed("Your glasses have the update, but ReGlass couldn't confirm the result. " + restartNote)
            case .unexpectedApply:
                return .unconfirmed("Your glasses started installing on their own. " + restartNote)
            case .confirmMismatch(let got, let want):
                return .failed("Your glasses restarted on \(got), not \(want).")
            case .timedOut(let what):
                return installing ? .unconfirmed("Your glasses stopped answering (\(what)). " + restartNote)
                                  : .failed("Your glasses stopped answering (\(what)). Nothing was installed.")
            case .busy:
                return .failed("Another firmware update is running.")
            case .planInvalid(let what):
                return .failed("The update from Meta didn't check out (\(what)). Nothing was installed.")
            }
        }
        let detail = (error as? ReGlassError)?.errorDescription ?? "Something went wrong."
        return installing ? .unconfirmed(detail + " " + restartNote) : .failed(detail + " Nothing was installed.")
    }

    private func finishFirmwareUpdate(_ outcome: FirmwareUpdateState.Outcome) {
        let finishedTarget = firmwareUpdate.run?.target
        clearFirmwareAway()
        firmwareTask = nil
        firmwareUpdate.run = nil
        firmwareUpdate.outcome = outcome
        switch outcome {
        case .updated(let version):
            firmwareUpdate.check = .upToDate(version)
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [Self.firmwareAvailableNotificationID])
            log.add("Firmware: updated — the glasses run \(version)")
        case .rehearsed: log.add("Firmware: rehearsal done — the whole update was sent; nothing was installed")
        case .stopped(let why): log.add("Firmware: stopped — \(why)")
        case .unconfirmed(let why):
            log.add("Firmware: sent, result unconfirmed — \(why)")
            // The glasses report their build on every connection: when it's the target, the update is confirmed.
            if let target = finishedTarget { firmwareAwaitingVersion = target }
        case .failed(let why): log.add("Firmware: didn't finish — \(why)")
        }
        firmwareApplyStarted = false
        endWakeWordBackgroundTime()
        wakeWordInstallActive = false
        // The firmware may have changed: read the glasses' resources again on the next connection.
        wakeWordReadFrom = nil
        live.connection = .idle
        connectIfReady()
    }

    /// An update that ended "unconfirmed" becomes "updated" the moment the glasses report the target build on any
    /// connection (they report it every time they connect).
    private func confirmFirmwareFromLive() {
        guard let target = firmwareAwaitingVersion, currentFirmwareVersion == target else { return }
        firmwareAwaitingVersion = nil
        firmwareUpdate.check = .upToDate(target)
        if case .unconfirmed? = firmwareUpdate.outcome { firmwareUpdate.outcome = .updated(target) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.firmwareAvailableNotificationID])
        log.add("Firmware: confirmed — the glasses report \(target) after the update")
    }

    /// ReGlass left the screen. Before the install that would stall the transfer (iOS suspends the app), so a
    /// notification asks the wearer back, and the update stops cleanly after `awayGrace` if ReGlass is still away.
    private func firmwareLeftScreen() {
        guard var run = firmwareUpdate.run, run.stage < .installing, !firmwareApplyStarted, run.away == nil else {
            return
        }
        run.away = Date()
        firmwareUpdate.run = run
        let grace = FirmwareUpdateState.awayGrace
        log.add("Firmware: ReGlass left the screen before the install; it stops in \(Int(grace)) s unless ReGlass is back")
        Task { await self.postFirmwareAwayNotification(rehearsal: run.rehearsal) }
        firmwareAwayTask?.cancel()
        firmwareAwayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(grace)) } catch { return }
            guard let self, self.firmwareUpdate.run?.away != nil, !self.firmwareApplyStarted else { return }
            self.firmwareStopReason = "ReGlass was closed during the update."
            self.log.add("Firmware: ReGlass stayed off screen; stopping before the install")
            self.firmwareTask?.cancel()
        }
    }

    private func firmwareBackOnScreen() {
        guard var run = firmwareUpdate.run, run.away != nil else { return }
        run.away = nil
        firmwareUpdate.run = run
        clearFirmwareAway()
        log.add("Firmware: ReGlass is back on screen; the update continues")
    }

    private func clearFirmwareAway() {
        firmwareAwayTask?.cancel()
        firmwareAwayTask = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.firmwareAwayNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.firmwareAwayNotificationID])
    }

    private func postFirmwareAwayNotification(rehearsal: Bool) async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = rehearsal ? "Update rehearsal in progress" : "Your glasses are updating"
        content.body = "Open ReGlass within \(Int(FirmwareUpdateState.awayGrace)) seconds to keep it going. "
            + "If it stops, nothing is installed."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "reglass.glasses"
        let request = UNNotificationRequest(identifier: Self.firmwareAwayNotificationID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Audio DSP settings (svc31) & Case charging watch

    /// Writes the assistant switch (on) and "Hey Meta" (`heyMetaEnabled`) to the glasses — Meta's defaults — and
    /// remembers the pair once the glasses confirm.
    private func applyWakeSettings(reason: String) {
        guard let connection, live.connection.isConnected, let serial = paired?.serial else { return }
        let settings = GlassesAudioSettings(assistantEnabled: true, wakeWordEnabled: heyMetaEnabled)
        let on = heyMetaEnabled
        Task { [weak self] in
            do {
                let ok = try await connection.setAudioSettings(settings)
                guard let self else { return }
                if ok { UserDefaults.standard.set(serial, forKey: Self.wakeSettingsAppliedKey) }
                self.log.add("Wake word: assistant on, Hey Meta \(on ? "on" : "off") (\(reason); "
                    + "\(ok ? "confirmed by the glasses" : "not confirmed"))")
            } catch {
                let detail = (error as? ReGlassError).map { String(describing: $0) } ?? "error"
                self?.log.add("Wake word: the Hey Meta setting didn't reach the glasses (\(detail))")
            }
        }
    }

    private func applyAudioSettings(_ settings: GlassesAudioSettings) {
        guard let connection, live.connection.isConnected else { return }
        Task { [weak self] in
            do {
                let ok = try await connection.setAudioSettings(settings)
                guard let self else { return }
                var names: [String] = []
                if let avc = settings.adaptiveVolume { names.append("adaptive volume \(avc ? "on" : "off")") }
                if let spatial = settings.spatialAudio { names.append("spatial audio \(spatial ? "on" : "off")") }
                self.log.add("Audio: \(names.joined(separator: ", ")) (\(ok ? "confirmed by the glasses" : "not confirmed"))")
            } catch {
                let detail = (error as? ReGlassError).map { String(describing: $0) } ?? "error"
                self?.log.add("Audio: setting didn't reach the glasses (\(detail))")
            }
        }
    }

    /// Watches for the glasses sitting in the case below 80 % without charging for 60 s (dirty contacts or a
    /// misaligned nose bridge), and posts a time-sensitive notification once per in-case episode.
    private func checkCaseCharging(_ current: GlassesLive) {
        let seatedUncharged = current.connection.isConnected
            && current.inCase == true
            && !current.charging
            && (current.battery ?? 100) < 80
        guard seatedUncharged else {
            caseChargeWatchTask?.cancel()
            caseChargeWatchTask = nil
            if notChargingInCase { notChargingInCase = false }
            if current.charging || current.inCase == false || !current.connection.isConnected {
                if caseChargeAlerted {
                    caseChargeAlerted = false
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: [Self.caseNotChargingNotificationID]
                    )
                }
            }
            return
        }
        guard !caseChargeAlerted, caseChargeWatchTask == nil else { return }
        caseChargeWatchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.caseNotChargingWait)
            } catch {
                return
            }
            guard let self else { return }
            self.caseChargeWatchTask = nil
            guard self.live.connection.isConnected,
                  self.live.inCase == true,
                  !self.live.charging,
                  let battery = self.live.battery,
                  battery < 80 else { return }
            self.caseChargeAlerted = true
            self.notChargingInCase = true
            self.log.add("Case: glasses in the case at \(battery)% and not charging for 60 s; alerting")
            await self.postCaseNotChargingNotification(battery: battery, caseBattery: self.live.caseBattery,
                                                       caseCharging: self.live.caseCharging)
        }
    }

    private func postCaseNotChargingNotification(battery: Int, caseBattery: Int?, caseCharging: Bool) async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = "Glasses aren't charging"
        if caseBattery == 0, !caseCharging {
            content.body = "They're in the case at \(battery)%, and the case battery is empty."
        } else {
            content.body = "They're in the case at \(battery)%, but not charging. Check how they're seated on the nose bridge."
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "reglass.glasses"
        let request = UNNotificationRequest(identifier: Self.caseNotChargingNotificationID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Meta sign-in

    /// Opens Meta's email-code sign-in. Returns a short reason when it can't start.
    @discardableResult
    func beginSignIn() -> String? {
        do {
            let flow = SignInFlow(try account.beginSignIn())
            signIn = flow
            flow.start()
            return nil
        } catch {
            return (error as? ReGlassError)?.errorDescription ?? "Sign-in couldn't start."
        }
    }

    func cancelSignIn() {
        account.cancelSignIn()
        signIn = nil
    }

    /// Forgets only ReGlass's cached Meta login. The owner key and the glasses are untouched.
    func signOut() {
        account.signOut()
    }
}
