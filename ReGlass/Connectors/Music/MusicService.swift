import AVFoundation
import Foundation
import ReGlassAssistant
import MediaPlayer
import MusicKit
import UIKit

/// Apple Music for the assistant: permission, whether the Apple Music catalog is reachable, and the three jobs the
/// tools hand over (play something, control the player, say what's playing). Results are short facts for Claude;
/// the activity log gets kinds, states and timings only, never what was asked for or played.
@MainActor
final class MusicService: ObservableObject {
    /// Whether ReGlass can search the Apple Music catalog, for Settings and for choosing where to look.
    enum CatalogAccess: Hashable {
        case unknown, checking, reachable
        /// MusicKit gets no developer token: the MusicKit App Service isn't enabled for ReGlass's App ID.
        case needsDeveloperSetup
        /// Apple Music wants its privacy notice seen: open the Music app once.
        case needsMusicApp
        case notSignedIn
        case noSubscription
        case offline
        case unreachable

        var logLabel: String {
            switch self {
            case .unknown: return "unknown"
            case .checking: return "checking"
            case .reachable: return "reachable"
            case .needsDeveloperSetup: return "unavailable (no developer token: MusicKit App Service off)"
            case .needsMusicApp: return "unavailable (Music app needs opening)"
            case .notSignedIn: return "unavailable (not signed in)"
            case .noSubscription: return "unavailable (no subscription)"
            case .offline: return "unavailable (offline or slow)"
            case .unreachable: return "unavailable (error)"
            }
        }

        /// Why the catalog couldn't help, as a clause for Claude.
        var reason: String? {
            switch self {
            case .unknown, .checking, .reachable: return nil
            case .needsDeveloperSetup:
                return "ReGlass can't search the Apple Music catalog yet (a one-time setup in the owner's Apple developer account is missing)"
            case .needsMusicApp: return "Apple Music needs the Music app opened once on the iPhone"
            case .notSignedIn: return "the iPhone isn't signed in to Apple Music"
            case .noSubscription: return "this Apple ID can't play the Apple Music catalog (no subscription)"
            case .offline: return "Apple Music couldn't be reached (no internet connection?)"
            case .unreachable: return "Apple Music didn't answer"
            }
        }

        /// Known to be blocked until the owner does something.
        var isBlocked: Bool {
            switch self {
            case .needsDeveloperSetup, .needsMusicApp, .notSignedIn, .noSubscription: return true
            default: return false
            }
        }
    }

    enum ControlAction: String, CaseIterable {
        case pause, resume, next, previous, restart
        case shuffleOn = "shuffle_on", shuffleOff = "shuffle_off"
        case repeatOne = "repeat_one", repeatAll = "repeat_all", repeatOff = "repeat_off"
    }

    static let shared = MusicService()

    @Published private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @Published private(set) var catalog: CatalogAccess = .unknown
    /// Sync Library is off: playlists from the owner's other devices aren't in the library.
    @Published private(set) var cloudLibraryOff = false

    private let log: (String) -> Void
    private var catalogNotedAt: Date?
    /// "Stop the music" during a voice turn: the glasses paused the music for the turn and resume it when the turn
    /// ends, so ReGlass pauses it again then.
    private var pauseAfterTurn: Task<Void, Never>?
    private var loggedCatalog: CatalogAccess = .unknown
    private(set) lazy var playback = MusicPlayback(log: log)

    private init() {
        let activity = GlassesController.shared.log
        log = { activity.add($0) }
    }

    // MARK: Permission

    var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    func refreshAuthorization() {
        let now = MusicAuthorization.currentStatus
        if now != authorization { authorization = now }
    }

    func connectorStatus() -> ConnectorStatus {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return .ready
        case .notDetermined:
            return .needsSetup(message: "Let ReGlass play and control Apple Music.", action: "Allow Access")
        case .denied:
            return .needsSetup(message: "Apple Music access is off for ReGlass. Turn it on in iPhone Settings.",
                               action: "Open iPhone Settings")
        case .restricted:
            return .unavailable("Apple Music is restricted on this iPhone.")
        @unknown default:
            return .unavailable("Apple Music isn't available on this iPhone.")
        }
    }

    func setUp() async {
        // iOS asks only once; after a "Don't Allow" the switch lives in the Settings app.
        if MusicAuthorization.currentStatus == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { _ = await UIApplication.shared.open(url) }
            return
        }
        if MusicAuthorization.currentStatus == .notDetermined {
            let status = await MusicAuthorization.request()
            log("Music: access \(status == .authorized ? "allowed" : "not allowed")")
        }
        refreshAuthorization()
        if isAuthorized { Task { await checkCatalog(force: true) } }
    }

    // MARK: Catalog reachability

    /// Asks the catalog one tiny question and reads the subscription, for Settings. Skipped if checked recently.
    func checkCatalog(force: Bool) async {
        refreshAuthorization()
        guard isAuthorized, catalog != .checking else { return }
        if !force, let noted = catalogNotedAt, Date().timeIntervalSince(noted) < 120, catalog != .unknown { return }
        catalog = .checking
        var result: CatalogAccess
        do {
            try await MusicCatalogResolver.probe()
            result = .reachable
        } catch {
            result = Self.classify(error)
            log("Music: catalog check failed (\(Self.errorLabel(error)))")
        }
        do {
            let subscription = try await musicWithTimeout(4) { try await MusicSubscription.current }
            cloudLibraryOff = !subscription.hasCloudLibraryEnabled
            if result == .reachable, !subscription.canPlayCatalogContent { result = .noSubscription }
        } catch {
            if result == .unreachable, Self.classify(error) == .needsMusicApp { result = .needsMusicApp }
        }
        note(result)
    }

    private func note(_ access: CatalogAccess) {
        catalog = access
        catalogNotedAt = Date()
        if access != loggedCatalog {
            loggedCatalog = access
            log("Music: catalog \(access.logLabel)")
        }
    }

    /// Skip the catalog for ten minutes after it was found blocked, then look again (the owner may have fixed it).
    private var shouldTryCatalog: Bool {
        guard catalog.isBlocked, let noted = catalogNotedAt else { return true }
        return Date().timeIntervalSince(noted) > 10 * 60
    }

    // MARK: Play

    func play(_ request: MusicRequest) async -> ToolResult {
        guard isAuthorized else { return accessFailure() }
        cancelPauseAfterTurn()
        let begun = Date()
        var flags = [request.kind.rawValue]
        if let shuffle = request.shuffle { flags.append(shuffle ? "shuffle" : "in order") }
        if request.newest { flags.append("newest") }
        log("Music: play request (\(flags.joined(separator: ", "))) while \(MusicPlayback.appState)")

        var picks: [MusicPick] = []
        var catalogProblem: CatalogAccess?
        if request.kind != .library {
            // One of the owner's own playlists with that name wins over the catalog.
            if request.kind == .playlist || request.kind == .any,
               let mine = MusicLibraryLookup.playlist(request.query, minimum: request.kind == .playlist ? 65 : 90) {
                picks.append(mine)
            } else if shouldTryCatalog {
                let searchBegun = Date()
                do {
                    if let found = try await MusicCatalogResolver.resolve(request) { picks.append(found) }
                    note(.reachable)
                    log("Music: catalog search \(MusicPlayback.seconds(since: searchBegun)), \(picks.isEmpty ? "nothing" : "found")")
                } catch {
                    if Task.isCancelled { return Self.cancelled }
                    let access = Self.classify(error)
                    catalogProblem = access
                    log("Music: catalog search failed after \(MusicPlayback.seconds(since: searchBegun)) (\(Self.errorLabel(error)))")
                    note(access)
                }
            } else {
                catalogProblem = catalog
            }
        }
        if Task.isCancelled { return Self.cancelled }

        // The library: the only source for "my library", and the fallback when the catalog can't help. Looking in it
        // folds every title on the main actor, so it only runs when needed (here, or below if the catalog pick won't
        // play).
        if picks.isEmpty, let mine = MusicLibraryLookup.resolve(request) {
            picks.append(mine)
        }
        guard !picks.isEmpty else { return notFound(request, catalogProblem) }

        // The whole call must finish inside the tool loop's 10 s limit, search included, so the reason something
        // didn't play reaches Claude instead of "took too long".
        var chain = picks.flatMap { [$0] + $0.alternatives }
        var triedLibrary = picks.contains { $0.source == .library }
        let deadline = begun.addingTimeInterval(Self.budget)
        var lastCode: Int?
        var index = 0
        while true {
            if index == chain.count {
                guard !triedLibrary, deadline.timeIntervalSinceNow > 2,
                      let mine = MusicLibraryLookup.resolve(request) else { break }
                triedLibrary = true
                chain += [mine] + mine.alternatives
            }
            let pick = chain[index]
            index += 1
            if Task.isCancelled { return Self.cancelled }
            let left = deadline.timeIntervalSinceNow
            guard left > 2 else { break }
            let shuffle = request.shuffle ?? pick.defaultShuffle
            log("Music: trying \(pick.kind.label) from the \(pick.source.label)")
            switch await playback.start(pick.queues, shuffle: shuffle, budget: left) {
            case .started(let snapshot, _):
                log("Music: playing \(MusicPlayback.seconds(since: begun)) after the request")
                return success(pick, snapshot, shuffle: shuffle,
                               libraryBecause: pick.source == .library && request.kind != .library ? catalogProblem : nil)
            case .failed(let code, _, let cancelled):
                if cancelled { return Self.cancelled }
                lastCode = code ?? lastCode
                if pick.source == .catalog, MusicPlayback.isSubscriptionProblem(code) {
                    catalogProblem = .noSubscription
                    note(.noSubscription)
                }
            }
        }
        return playbackFailure(lastCode)
    }

    /// Seconds one `play_music` call may take, search included (the tool loop cuts calls off at 10 s).
    private static let budget: TimeInterval = 8.5

    private func success(_ pick: MusicPick, _ snapshot: MusicSnapshot, shuffle: Bool,
                         libraryBecause problem: CatalogAccess?) -> ToolResult {
        var lines: [String] = []
        if let title = snapshot.title {
            lines.append("playing now: \"\(title)\"" + (snapshot.artist.map { " by \($0)" } ?? ""))
        } else {
            lines.append("playing now: yes (the song's name isn't available yet)")
        }
        lines.append("picked: " + Self.describe(pick, shuffle: shuffle))
        lines.append("from: " + (pick.source == .catalog ? "Apple Music" : "the owner's library, in the Music app"))
        if let then = Self.followUp(pick) { lines.append("then: " + then) }
        if let reason = problem?.reason { lines.append("note: played from the library because \(reason)") }
        if playback.onPhoneSpeaker { lines.append("note: the sound is coming from the iPhone's own speaker") }

        let title = pick.kind == .librarySongs ? (shuffle ? "Shuffled your library" : "Played your library")
                                               : "Played \(pick.name)"
        let detail = [pick.by, "Apple Music"].compactMap { $0 }.joined(separator: " · ")
        return .success(lines.joined(separator: "\n"), action: ToolAction(title: title, detail: detail))
    }

    private static func describe(_ pick: MusicPick, shuffle: Bool) -> String {
        let order = shuffle ? ", shuffled" : ""
        let count = pick.songCount.map { " (\($0) songs)" } ?? ""
        switch pick.kind {
        case .song:
            return "the song \"\(pick.name)\"" + (pick.by.map { " by \($0)" } ?? "")
        case .artistSongs:
            return pick.source == .catalog
                ? "\(pick.name)'s top songs\(count)\(order)"
                : "songs by \(pick.name) in the library\(count)\(order)"
        case .album:
            return "the album \"\(pick.name)\"" + (pick.by.map { " by \($0)" } ?? "") + count + (shuffle ? order : ", in order")
        case .playlist:
            return "the playlist \"\(pick.name)\"" + count + order
        case .station:
            return "the station \"\(pick.name)\"" + (pick.by.map { " (based on \($0))" } ?? "")
        case .librarySongs:
            return "the whole library\(count)\(order)"
        }
    }

    private static func followUp(_ pick: MusicPick) -> String? {
        switch pick.kind {
        case .song: return nil
        case .artistSongs: return "more of \(pick.name)'s songs"
        case .album: return "the rest of the album"
        case .playlist: return "the rest of the playlist"
        case .station: return "more songs like it, without end (it's a station)"
        case .librarySongs: return "more from the library"
        }
    }

    private func notFound(_ request: MusicRequest, _ problem: CatalogAccess?) -> ToolResult {
        log("Music: nothing found (\(request.kind.rawValue))")
        var text = request.kind == .library && request.query.isEmpty
            ? "The owner's library has no songs ReGlass can see."
            : "Nothing matching that was found."
        if let reason = problem?.reason { text += " Only the owner's library was searched: \(reason)." }
        return .failure(text, action: ToolAction(title: "Couldn't find that music", detail: "Apple Music"))
    }

    private func playbackFailure(_ code: Int?) -> ToolResult {
        let text: String
        switch code {
        case 1, 2: text = "The Music app refused to play it: this Apple ID can't play Apple Music catalog songs right now (subscription or sign-in)."
        case 3: text = "The Music app couldn't reach Apple Music (no internet connection?)."
        case 4: text = "The Music app couldn't find it in this country's Apple Music."
        default: text = "The Music app didn't start playing. Opening the Music app once on the iPhone may help."
        }
        return .failure(text, action: ToolAction(title: "Couldn't play music", detail: "Apple Music"))
    }

    // MARK: Controls

    /// Waits for the voice turn to end (at most a minute), then for six seconds pauses the music if the glasses
    /// resume it. The wearer's own tap on the glasses after that is left alone.
    private func keepPausedAfterTurn() {
        pauseAfterTurn?.cancel()
        pauseAfterTurn = Task { [weak self] in
            let started = Date()
            while AssistantController.shared.phase != .idle, Date().timeIntervalSince(started) < 60 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            let ended = Date()
            while Date().timeIntervalSince(ended) < 6 {
                guard let self, !Task.isCancelled else { return }
                if self.playback.snapshot().looksPlaying {
                    self.playback.pause()
                    self.log("Music: paused again after the glasses resumed it")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func cancelPauseAfterTurn() {
        pauseAfterTurn?.cancel()
        pauseAfterTurn = nil
    }

    func control(_ action: ControlAction) async -> ToolResult {
        guard isAuthorized else { return accessFailure() }
        let before = playback.snapshot()
        let musicPlaying = before.looksPlaying
        let otherApp = playback.otherAppPlaying(musicPlaying: musicPlaying)
        log("Music: control \(action.rawValue) (was \(before.stateLabel)\(otherApp ? ", another app playing" : ""))")

        switch action {
        case .pause:
            // While the wearer talks to ReGlass the glasses hold the music themselves and resume it afterwards: pause
            // it again once they do, so "stop the music" sticks.
            if AssistantController.shared.phase != .idle, !otherApp {
                if musicPlaying { playback.pause() }
                keepPausedAfterTurn()
                return .success("state: paused; it stays paused after this conversation" + Self.track(before),
                                action: ToolAction(title: "Paused music"))
            }
            guard musicPlaying else {
                if otherApp { return otherAppFailure("pause") }
                return .success("state: already paused or stopped" + Self.track(before), action: ToolAction(title: "Music was already paused"))
            }
            playback.pause()
            let (after, paused) = await playback.wait(seconds: 1.5) { !$0.looksPlaying }
            log("Music: pause \(paused ? "done" : "not confirmed") (\(after.stateLabel))")
            return paused
                ? .success("state: paused" + Self.track(after), action: ToolAction(title: "Paused music"))
                : .failure("The Music app didn't pause.", action: ToolAction(title: "Couldn't pause music"))

        case .resume:
            cancelPauseAfterTurn()
            if musicPlaying {
                return .success("state: already playing" + Self.track(before), action: ToolAction(title: "Music was already playing"))
            }
            if otherApp {
                return .failure("Another app is playing audio, so ReGlass didn't start Apple Music over it.",
                                action: ToolAction(title: "Didn't resume music"))
            }
            guard before.itemKey != nil else {
                return .failure("Nothing is queued in the Music app. Ask for something to play.",
                                action: ToolAction(title: "Nothing to resume"))
            }
            playback.resume()
            var (after, playing) = await playback.wait(seconds: 2) { $0.looksPlaying }
            if !playing, !Task.isCancelled {
                log("Music: resume not confirmed (\(after.stateLabel)); asking again")
                playback.resume()
                (after, playing) = await playback.wait(seconds: 1.5) { $0.looksPlaying }
            }
            log("Music: resume \(playing ? "done" : "not confirmed") (\(after.stateLabel))")
            return playing
                ? .success("state: playing" + Self.track(after), action: ToolAction(title: "Resumed music", detail: after.title))
                : .failure("The Music app didn't start playing.", action: ToolAction(title: "Couldn't resume music"))

        case .next, .previous:
            if otherApp { return otherAppFailure("skip") }
            guard before.itemKey != nil else {
                return .failure("Nothing is playing in the Music app.", action: ToolAction(title: "Nothing to skip"))
            }
            if action == .next { playback.next() } else { playback.previous() }
            let (after, changed) = await playback.wait(seconds: 2) { $0.itemKey != before.itemKey }
            log("Music: \(action.rawValue) \(changed ? "done" : "no change") (\(after.stateLabel))")
            guard changed else {
                return .failure(action == .next ? "The Music app didn't move to another song (maybe the end of the queue)."
                                                : "The Music app didn't go back a song.",
                                action: ToolAction(title: action == .next ? "Couldn't skip" : "Couldn't go back"))
            }
            let title = action == .next ? "Skipped to the next song" : "Went back a song"
            return .success("state: \(after.looksPlaying ? "playing" : after.stateLabel)" + Self.track(after),
                            action: ToolAction(title: title, detail: after.title))

        case .restart:
            guard before.itemKey != nil, !otherApp else { return otherApp ? otherAppFailure("restart") : nothingPlaying() }
            playback.restart()
            return .success("state: started the song over" + Self.track(before), action: ToolAction(title: "Started the song over"))

        case .shuffleOn, .shuffleOff:
            if otherApp { return otherAppFailure("shuffle") }
            playback.setShuffle(action == .shuffleOn)
            let on = action == .shuffleOn
            return .success("shuffle: \(on ? "on" : "off")", action: ToolAction(title: on ? "Shuffle on" : "Shuffle off"))

        case .repeatOne, .repeatAll, .repeatOff:
            if otherApp { return otherAppFailure("repeat") }
            let (mode, word): (MPMusicRepeatMode, String) = action == .repeatOne ? (.one, "this song")
                : action == .repeatAll ? (.all, "all") : (.none, "off")
            playback.setRepeat(mode)
            return .success("repeat: \(word)", action: ToolAction(title: mode == .none ? "Repeat off" : "Repeat \(word)"))
        }
    }

    private func otherAppFailure(_ verb: String) -> ToolResult {
        .failure("Apple Music isn't what's playing; another app is, and ReGlass can't \(verb) it. "
                 + "The glasses' touchpad can: tap to pause or play, double-tap to skip, triple-tap to go back.",
                 action: ToolAction(title: "Another app is playing"))
    }

    private func nothingPlaying() -> ToolResult {
        .failure("Nothing is playing in the Music app.", action: ToolAction(title: "Nothing playing"))
    }

    // MARK: Now playing

    func nowPlaying() async -> ToolResult {
        guard isAuthorized else { return accessFailure() }
        let snapshot = playback.snapshot()
        let otherApp = playback.otherAppPlaying(musicPlaying: snapshot.looksPlaying)
        log("Music: now playing checked (\(snapshot.stateLabel)\(otherApp ? ", another app playing" : ""))")
        if snapshot.looksPlaying || (snapshot.itemKey != nil && !otherApp) {
            var lines = ["app: Apple Music", "state: \(snapshot.looksPlaying ? "playing" : snapshot.stateLabel)"]
            if let title = snapshot.title { lines.append("title: \(title)") }
            if let artist = snapshot.artist { lines.append("artist: \(artist)") }
            if let album = snapshot.album { lines.append("album: \(album)") }
            if snapshot.title == nil { lines.append("note: the Music app didn't give the song's name") }
            return .success(lines.joined(separator: "\n"), action: ToolAction(title: "Checked what's playing", detail: snapshot.title))
        }
        if otherApp {
            return .success("app: another app (not Apple Music)\nnote: ReGlass can't see what it's playing",
                            action: ToolAction(title: "Checked what's playing", detail: "Another app"))
        }
        return .success("state: nothing is playing", action: ToolAction(title: "Checked what's playing", detail: "Nothing"))
    }

    // MARK: Helpers

    private func accessFailure() -> ToolResult {
        let text: String
        switch MusicAuthorization.currentStatus {
        case .denied: text = "Apple Music access for ReGlass is off in the iPhone's Settings (Settings → ReGlass)."
        case .restricted: text = "Apple Music is restricted on this iPhone."
        default: text = "ReGlass isn't allowed to use Apple Music yet. The owner can allow it in ReGlass: Settings → Connectors → Apple Music."
        }
        return .failure(text, action: ToolAction(title: "Apple Music needs access"))
    }

    private static let cancelled = ToolResult.failure("Stopped before the music started.", action: ToolAction(title: "Stopped"))

    private static func track(_ snapshot: MusicSnapshot) -> String {
        guard let title = snapshot.title else { return "" }
        return "\nsong: \"\(title)\"" + (snapshot.artist.map { " by \($0)" } ?? "")
    }

    static func classify(_ error: Error) -> CatalogAccess {
        if let token = error as? MusicTokenRequestError {
            switch token {
            case .developerTokenRequestFailed: return .needsDeveloperSetup
            case .privacyAcknowledgementRequired: return .needsMusicApp
            case .userNotSignedIn, .userTokenRevoked: return .notSignedIn
            case .permissionDenied, .userTokenRequestFailed, .unknown: return .unreachable
            @unknown default: return .unreachable
            }
        }
        if let subscription = error as? MusicSubscription.Error, subscription == .privacyAcknowledgementRequired {
            return .needsMusicApp
        }
        if let data = error as? MusicDataRequest.Error {
            return data.status == 401 || data.status == 403 ? .needsDeveloperSetup : .unreachable
        }
        if error is MusicTimeout { return .offline }
        if (error as NSError).domain == NSURLErrorDomain { return .offline }
        return .unreachable
    }

    /// The error's kind and code, never its message (which can quote the request).
    static func errorLabel(_ error: Error) -> String {
        if let token = error as? MusicTokenRequestError { return "token: \(token.rawValue)" }
        if let subscription = error as? MusicSubscription.Error { return "subscription: \(subscription.rawValue)" }
        if let data = error as? MusicDataRequest.Error { return "http \(data.status), code \(data.code)" }
        if error is MusicTimeout { return "timed out" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
