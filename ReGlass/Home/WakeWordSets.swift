import ReGlassKit
import SwiftUI

/// The wake word sets kept on this iPhone, for the Wake Word screen: which are there, an import in progress, and
/// what the last import or removal did. The files themselves live in ReGlassKit's `WakeWordLibrary`
/// (Application Support/ReGlass/WakeWord); installs go through `GlassesController.installWakeWord`.
@MainActor
final class WakeWordSets: ObservableObject {
    static let shared = WakeWordSets()

    /// What the last import, check or removal did, in plain words.
    enum Outcome: Equatable {
        case imported(String)
        case removed(String)
        case problem(String)
    }

    @Published private(set) var factory: WakeWordLibrary.StoredSet?
    @Published private(set) var custom: WakeWordLibrary.StoredSet?
    /// Reading and checking a picked set.
    @Published private(set) var importing = false
    /// Checking a kept set's files again before an install takes the glasses.
    @Published private(set) var checking: WakeWord?
    @Published private(set) var downloadProgress: String?
    @Published var outcome: Outcome?
    /// Meta refused the sign-in during the last factory download: offer signing in again.
    @Published private(set) var downloadNeedsSignIn = false
    private var downloadTask: Task<Void, Never>?

    private let glasses: GlassesController

    private init() {
        glasses = GlassesController.shared
        reload()
    }

    func stored(_ wakeWord: WakeWord) -> WakeWordLibrary.StoredSet? {
        wakeWord == .heyMeta ? factory : custom
    }

    var isBusy: Bool { importing || checking != nil || downloadProgress != nil }

    /// Fetches a complete factory restore set. Installing it remains a separate, confirmed action.
    func downloadFactorySet() {
        guard !isBusy else { glasses.log.add("Wake word: factory download ignored (busy)"); return }
        guard let paired = glasses.paired else {
            glasses.log.add("Wake word: factory download can't start (no paired glasses)"); return
        }
        guard let build = glasses.live.firmware ?? paired.firmware else {
            glasses.log.add("Wake word: factory download can't start (firmware not known yet)"); return
        }
        outcome = nil
        downloadNeedsSignIn = false
        downloadProgress = "Signing in for the factory download…"
        glasses.log.add("Wake word: factory download started (firmware \(build))")
        let library = glasses.wakeWordLibrary
        let account = glasses.account
        downloadTask = Task { [weak self] in
            do {
                let set = try await library.downloadFactorySet(account: account, build: build, serial: paired.serial) { [weak self] text in
                    GlassesController.shared.log.add("Wake word: factory download — \(text)")
                    await self?.showDownloadProgress(text)
                }
                self?.outcome = .imported(set.name)
                GlassesController.shared.log.add("Wake word: factory set downloaded to this iPhone (\(set.name)); tap Install to send it to the glasses")
            } catch {
                let kitError = error as? ReGlassError
                if kitError != .cancelled {
                    self?.downloadNeedsSignIn = kitError == .signInRequired
                    self?.outcome = .problem(kitError?.errorDescription ?? "The factory download couldn't finish.")
                    GlassesController.shared.log.add("Wake word: factory download failed (\(kitError.map { "\($0)" } ?? "unknown"))")
                } else {
                    GlassesController.shared.log.add("Wake word: factory download cancelled")
                }
            }
            self?.downloadProgress = nil
            self?.downloadTask = nil
            self?.reload()
        }
    }

    private func showDownloadProgress(_ text: String) { downloadProgress = text }

    func cancelDownload() { downloadTask?.cancel() }

    func reload() {
        factory = glasses.wakeWordLibrary.stored(.heyMeta)
        custom = glasses.wakeWordLibrary.stored(.custom)
    }

    /// Checks and keeps the set the wearer picked in Files. Nothing is sent to the glasses.
    func importSet(_ picked: Result<URL, Error>) {
        guard !isBusy else { return }
        let url: URL
        switch picked {
        case .success(let chosen): url = chosen
        case .failure: outcome = .problem("ReGlass couldn't open what you picked. Try again."); return
        }
        importing = true
        outcome = nil
        let library = glasses.wakeWordLibrary
        Task { [weak self] in
            let result: Result<WakeWordLibrary.StoredSet, Error>
            do { result = .success(try await library.importSet(from: url)) } catch { result = .failure(error) }
            guard let self else { return }
            importing = false
            reload()
            switch result {
            case .success(let set):
                outcome = .imported(set.name)
                glasses.log.add("Wake word: \(set.wakeWord == .heyMeta ? "factory" : "custom") set imported")
            case .failure(let error):
                let kitError = error as? ReGlassError
                if kitError == .cancelled { return }
                outcome = .problem(kitError?.errorDescription ?? "ReGlass can't use this set. Nothing was copied.")
                glasses.log.add("Wake word: set not imported")
            }
        }
    }

    /// Deletes a kept set from this iPhone. The glasses keep whatever they have.
    func remove(_ wakeWord: WakeWord) {
        guard !isBusy, let set = stored(wakeWord) else { return }
        do {
            try glasses.wakeWordLibrary.remove(wakeWord)
            outcome = .removed(set.name)
            glasses.log.add("Wake word: \(wakeWord == .heyMeta ? "factory" : "custom") set removed from this iPhone")
        } catch {
            outcome = .problem("ReGlass couldn't remove the set. Try again.")
        }
        reload()
    }

    /// Checks the kept files once more, then installs. The live connection lets go only after they pass, so a
    /// damaged set never costs a reconnect.
    func install(_ wakeWord: WakeWord) {
        guard !isBusy, stored(wakeWord) != nil, glasses.canChangeWakeWord else { return }
        checking = wakeWord
        outcome = nil
        let library = glasses.wakeWordLibrary
        Task { [weak self] in
            var problem: String?
            do { try await library.check(wakeWord) } catch {
                problem = (error as? ReGlassError)?.errorDescription ?? "The wake word files are missing or damaged."
            }
            guard let self else { return }
            checking = nil
            if let problem {
                outcome = .problem(problem)
                reload()
                return
            }
            glasses.installWakeWord(wakeWord)
        }
    }
}
