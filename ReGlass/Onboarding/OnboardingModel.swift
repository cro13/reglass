import Combine
import Foundation
import ReGlassKit
import SwiftUI

/// "Connect your Meta glasses": the steps, what was chosen, and the setup run.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Comparable {
        case welcome, search, signIn, transfer, setup, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum Mode { case enroll, reconnect }

    struct Problem: Equatable {
        var title: String
        var message: String
        /// Offer "Transfer to ReGlass" (sign in and change owner, reusing the saved key).
        var offerTransfer = false
        /// Offer signing in again (expired login, wrong account).
        var offerSignIn = false
        var offerRetry = true
    }

    enum RunState: Equatable {
        case idle
        case running
        case failed(Problem)
        case succeeded
    }

    @Published private(set) var step: Step
    @Published private(set) var forward = true
    @Published private(set) var selected: FoundGlasses?
    @Published private(set) var mode: Mode = .enroll
    @Published private(set) var run: RunState = .idle
    @Published private(set) var stage: SetupStage?
    @Published private(set) var outcome: GlassesSetupResult?
    @Published private(set) var ownershipMayHaveMoved = false

    let discovery = GlassesDiscovery()
    private let glasses: GlassesController
    private var task: Task<Void, Never>?
    /// Each run's results and progress are dropped once a newer run (or a close) has replaced it.
    private var runGeneration = 0
    private var subscriptions = Set<AnyCancellable>()
    /// Where this flow opened: Welcome on first launch, Search when set up again from Settings. Nothing before it.
    private let firstStep: Step

    init(glasses: GlassesController, startAt: Step) {
        self.glasses = glasses
        step = startAt
        firstStep = startAt
        if step == .search { discovery.start() }
        // Move on by itself once Meta's sign-in finishes.
        glasses.$accountStatus.removeDuplicates().sink { [weak self] status in
            guard let self, self.step == .signIn, status == .signedIn else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.step == .signIn, self.glasses.accountStatus == .signedIn else { return }
                self.go(.transfer)
            }
        }.store(in: &subscriptions)
    }

    var stages: [SetupStage] { SetupStage.stages(enrolling: mode == .enroll) }

    var canGoBack: Bool {
        if step == firstStep { return false }
        switch step {
        case .welcome, .done: return false
        case .setup: return run != .running
        default: return true
        }
    }

    // MARK: Navigation

    func go(_ next: Step) {
        forward = next > step
        if next == .search { discovery.start() } else if step == .search { discovery.stop() }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { step = next }
    }

    func back() {
        guard canGoBack else { return }
        switch step {
        case .search: go(.welcome)
        case .signIn:
            // While Meta's form is up, back moves through Meta's screens; from the first one it ends the sign-in.
            if let flow = glasses.signIn {
                if !flow.back() { glasses.cancelSignIn() }
            } else {
                go(.search)
            }
        case .transfer: go(.signIn)
        case .setup: go(mode == .enroll ? .transfer : .search)
        default: break
        }
    }

    // MARK: Choosing glasses

    func choose(_ found: FoundGlasses) {
        guard step == .search else { return }   // a second tap while the first one moves on
        selected = found
        discovery.stop()
        switch GlassesVault.ownerKeyState() {
        case .present:
            // ReGlass set glasses up before (or a setup was interrupted): try the saved key first, no Meta needed.
            mode = .reconnect
            go(.setup)
            startSetup()
        case .none:
            mode = .enroll
            go(.signIn)
        case .unreadable:
            mode = .reconnect
            go(.setup)
            run = .failed(Problem(title: "Unlock your iPhone",
                                  message: "ReGlass keeps its saved key locked until this iPhone has been unlocked. Unlock it, then try again."))
        case .damaged:
            mode = .reconnect
            go(.setup)
            run = .failed(Problem(title: "ReGlass's saved key is damaged",
                                  message: "Your glasses aren't affected. To start fresh, delete and reinstall ReGlass, then set your glasses up again.",
                                  offerRetry: false))
        }
    }

    // MARK: Transfer and setup

    /// The wearer confirmed on the Transfer screen: make ReGlass the owner (sign-in done), reusing any saved key.
    func transfer() {
        mode = .enroll
        go(.setup)
        startSetup()
    }

    func retry() {
        // After an ownership attempt, always try the saved key first: ownership may already have moved.
        if ownershipMayHaveMoved, GlassesVault.ownerKeyState() == .present { mode = .reconnect }
        // Every ownership transfer needs its own tap on Transfer, so a retry goes back to that screen.
        if mode == .enroll {
            go(.transfer)
            return
        }
        startSetup()
    }

    func signInAgain() {
        glasses.signOut()
        mode = .enroll
        go(.signIn)
    }

    private func startSetup() {
        guard let selected else { go(.search); return }
        guard run != .running else { return }
        let previous = task
        previous?.cancel()
        runGeneration += 1
        let generation = runGeneration
        run = .running
        stage = nil
        outcome = nil
        let mode = mode
        let ownership = GlassesOwnership(glasses: selected.id, account: glasses.account)
        let finder = discovery.finder
        let progress: @Sendable (SetupStage) -> Void = { [weak self] next in
            Task { @MainActor in self?.advance(to: next, generation: generation) }
        }
        glasses.log.add(mode == .enroll ? "Setup: transferring ownership to ReGlass" : "Setup: reconnecting with the saved key")
        task = Task { [weak self] in
            // One session at a time: a cancelled run must have let go of the glasses first.
            await previous?.value
            guard let self, generation == runGeneration else { return }
            await glasses.beginSetup()
            do {
                try Task.checkCancellation()
                if !selected.connectedToPhone {
                    // Not paired with this iPhone yet: iOS shows its own pairing prompt. Changes nothing on ownership.
                    progress(.connect)
                    try await finder.pair(selected.id)
                }
                let result = mode == .enroll
                    ? try await ownership.transfer(progress: progress)
                    : try await ownership.reconnect(progress: progress)
                guard generation == runGeneration else { return }
                finish(result)
            } catch {
                if ownership.ownerChangeAttempted { ownershipMayHaveMoved = true }
                guard generation == runGeneration else { return }
                fail(error)
            }
        }
    }

    /// Stops the run. It ends asynchronously; `fail` then shows the idle state with Try Again.
    func cancelSetup() {
        task?.cancel()
    }

    private func advance(to next: SetupStage, generation: Int) {
        guard generation == runGeneration, run == .running else { return }
        if let current = stage, next < current { return }
        withAnimation(.easeInOut(duration: 0.35)) { stage = next }
    }

    private func finish(_ result: GlassesSetupResult) {
        outcome = result
        withAnimation(.easeInOut(duration: 0.35)) {
            stage = nil
            run = .succeeded
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.go(.done)
        }
    }

    /// Done: remember the glasses and open ReGlass.
    func complete() {
        guard let selected, let outcome else { return }
        glasses.completeSetup(found: selected, result: outcome)
    }

    /// Leaves a re-setup started from Settings without changing anything more. Not offered while a run is going.
    func close() {
        let pending = task
        pending?.cancel()
        task = nil
        runGeneration += 1
        discovery.stop()
        if glasses.signIn != nil { glasses.cancelSignIn() }
        glasses.showingSetup = false
        let glasses = glasses
        Task {
            // The live connection comes back only once the cancelled run has let go of the glasses.
            await pending?.value
            glasses.cancelSetup()
            glasses.connectIfReady()
        }
    }

    private func fail(_ error: Error) {
        glasses.cancelSetup()
        let reglassError = error as? ReGlassError
        if reglassError == .cancelled || error is CancellationError || Task.isCancelled {
            run = .idle
            stage = nil
            return
        }
        withAnimation { run = .failed(problem(for: reglassError)) }
    }

    private func problem(for error: ReGlassError?) -> Problem {
        let moved = ownershipMayHaveMoved
            ? " Ownership may already have moved to ReGlass, so Try Again reconnects with ReGlass's saved key first."
            : ""
        let stoppedAnswering = Problem(
            title: "Your glasses stopped answering",
            message: "Keep them unfolded and close to your iPhone, make sure Meta AI is closed, then try again." + moved,
            offerTransfer: mode == .reconnect)
        switch error {
        case .noSavedIdentity?:
            return Problem(title: "ReGlass isn't set up on these glasses yet",
                           message: "Sign in with Meta and transfer them to ReGlass to continue.",
                           offerTransfer: true, offerRetry: false)
        case .keyRefused?:
            return Problem(title: "Your glasses didn't accept ReGlass",
                           message: "They were probably set up again with the Meta AI app. Transfer them back to ReGlass to continue.",
                           offerTransfer: true)
        case .serialMismatch?:
            return Problem(title: "These are different glasses",
                           message: "The glasses that answered aren't the ones ReGlass set up. Choose the right pair, or transfer these to ReGlass.",
                           offerTransfer: true)
        case .verificationIncomplete?, .timedOut?, .linkLost?:
            return stoppedAnswering
        case .keyUnavailable?:
            return Problem(title: "Unlock your iPhone",
                           message: "ReGlass keeps its saved key locked until this iPhone has been unlocked. Unlock it, then try again.")
        case .pairingDeclined?:
            return Problem(title: "Pairing was declined",
                           message: "Accept the Bluetooth pairing request when it appears, then try again.")
        case .bondStale?:
            return Problem(title: "Forget these glasses first",
                           message: "This iPhone was paired with them before, so Bluetooth won't connect. Open Settings → Bluetooth, tap the ⓘ next to these glasses and Forget This Device, then try again.")
        case .noAnswer?, .glassesUnknown?, .bluetoothOff?, .bluetoothDenied?, .bluetoothUnsupported?:
            // Nothing answered, so a transfer couldn't help: just try again.
            // Never an empty message: without ReGlassKit's own words, say what usually helps.
            let why = error?.errorDescription
                ?? "Make sure Bluetooth is on and your glasses are unfolded and close to your iPhone, then try again."
            return Problem(title: "Couldn't reach your glasses", message: why + moved)
        case .wrongOwnerAccount?:
            return Problem(title: "A different Meta account owns these glasses",
                           message: "Sign in with the Meta account you used to set them up.",
                           offerSignIn: true, offerRetry: false)
        case .signInRequired?:
            return Problem(title: "Meta sign-in didn't go through",
                           message: "Your sign-in may have expired. Sign in again to continue.",
                           offerSignIn: true, offerRetry: false)
        case .metaRejected?:
            return Problem(title: "Meta didn't accept the hand-over",
                           message: "Sign in again with the account that owns these glasses, then try again." + moved,
                           offerSignIn: true)
        case .network?:
            return Problem(title: "No connection to Meta", message: "Check that your iPhone is online, then try again." + moved)
        case .missingClientCredentials?:
            return Problem(title: "This build can't set up glasses",
                           message: "This build has no Meta client credentials. Run the token script in tools/meta-tokens (see docs/META-CREDENTIALS.md), then rebuild ReGlass.",
                           offerRetry: false)
        case .protocolFailure?, .missingSignInData?, .cancelled?, nil,
             // Wake word changes never happen during setup.
             .wakeWordUnavailable?, .wakeWordUnrecognised?, .wakeWordFilesDamaged?, .glassesNeedCharge?,
             .glassesTooWarm?, .wakeWordDeclined?, .wakeWordNotConfirmed?, .wakeWordRestoreNeedsCustom?,
             .wakeWordSetInvalid?, .wakeWordDownloadFailed?:
            return Problem(title: "Setup didn't finish",
                           message: (error?.errorDescription
                                     ?? "Something unexpected happened. Try again. If it happens again, see Troubleshooting in ReGlass's docs.")
                                     + moved,
                           offerTransfer: mode == .reconnect)
        }
    }
}
