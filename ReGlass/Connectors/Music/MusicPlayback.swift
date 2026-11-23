import AVFoundation
import Foundation
import MediaPlayer
import MusicKit
import UIKit

// Everything ReGlass plays goes to the Music app through `MPMusicPlayerController.systemMusicPlayer`. The Music app
// owns the playback: it keeps playing after ReGlass is suspended, shows on the Lock Screen as Music, and the glasses'
// touchpad (tap, double tap, swipes) keeps controlling it.
//
// ReGlass must never become the Now Playing app (see AssistantAudio): no MPRemoteCommandCenter, no
// MPNowPlayingInfoCenter, no applicationMusicPlayer / applicationQueuePlayer, and no playback of its own here.

/// One way to queue a pick in the Music app. A pick lists several, tried in order until one plays.
enum MusicQueue {
    /// Apple Music catalog songs (or a station) by store ID.
    case storeIDs([String])
    /// Apple Music catalog items (album, playlist, station, songs) by their play parameters from MusicKit.
    case playParameters([MusicKit.PlayParameters])
    /// The owner's library.
    case libraryQuery(MPMediaQuery)
    case libraryItems(MPMediaItemCollection)

    /// For the activity log: the route, never the content.
    var label: String {
        switch self {
        case .storeIDs(let ids): return "store ids (\(ids.count))"
        case .playParameters(let items): return "play parameters (\(items.count))"
        case .libraryQuery: return "library query"
        case .libraryItems(let items): return "library items (\(items.count))"
        }
    }

    var descriptor: MPMusicPlayerQueueDescriptor? {
        switch self {
        case .storeIDs(let ids):
            return ids.isEmpty ? nil : MPMusicPlayerStoreQueueDescriptor(storeIDs: ids)
        case .playParameters(let items):
            let parameters = items.compactMap(Self.parameters)
            return parameters.isEmpty ? nil : MPMusicPlayerPlayParametersQueueDescriptor(playParametersQueue: parameters)
        case .libraryQuery(let query):
            return MPMusicPlayerMediaItemQueueDescriptor(query: query)
        case .libraryItems(let items):
            return items.count == 0 ? nil : MPMusicPlayerMediaItemQueueDescriptor(itemCollection: items)
        }
    }

    /// MusicKit's play parameters are the Apple Music API's `playParams` ({id, kind}), which is what MediaPlayer takes.
    private static func parameters(_ item: MusicKit.PlayParameters) -> MPMusicPlayerPlayParameters? {
        guard let data = try? JSONEncoder().encode(item),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return MPMusicPlayerPlayParameters(dictionary: dictionary)
    }
}

/// Something found to play, and how to describe it to Claude and in Chats.
struct MusicPick {
    enum Kind {
        case song, artistSongs, album, playlist, station, librarySongs

        var label: String {
            switch self {
            case .song: return "song"
            case .artistSongs: return "artist"
            case .album: return "album"
            case .playlist: return "playlist"
            case .station: return "station"
            case .librarySongs: return "library"
            }
        }
    }

    enum Source {
        case catalog, library

        var label: String { self == .catalog ? "catalog" : "library" }
    }

    var kind: Kind
    var source: Source
    /// "Diamonds", "Rihanna", "Discovery Station", "your library".
    var name: String
    /// The artist or curator, when there is one.
    var by: String?
    var songCount: Int?
    var defaultShuffle: Bool
    var queues: [MusicQueue]
    /// Other picks to try if none of `queues` starts (an artist's station when their top songs won't play).
    var alternatives: [MusicPick] = []
}

/// The Music app's player, as ReGlass sees it.
struct MusicSnapshot {
    var state: MPMusicPlaybackState
    var rate: Float
    var time: TimeInterval
    var itemKey: String?
    var title: String?
    var artist: String?
    var album: String?

    var looksPlaying: Bool { state == .playing || rate > 0 }

    var stateLabel: String {
        switch state {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused: return "paused"
        case .interrupted: return "interrupted"
        case .seekingForward, .seekingBackward: return "seeking"
        @unknown default: return "unknown"
        }
    }
}

@MainActor
final class MusicPlayback {
    enum StartOutcome {
        case started(MusicSnapshot, queue: MusicQueue)
        /// `code` is MediaPlayer's error code when it gave one; `definitive` when retrying can't help (not found,
        /// not allowed, no subscription).
        case failed(code: Int?, definitive: Bool, cancelled: Bool)
    }

    private let log: (String) -> Void
    private var listening = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    private var player: MPMusicPlayerController {
        let player = MPMusicPlayerController.systemMusicPlayer
        if !listening {
            // Keeps `playbackState` fresh. Only notifications to ReGlass; it doesn't take Now Playing or remote commands.
            player.beginGeneratingPlaybackNotifications()
            listening = true
        }
        return player
    }

    // MARK: Reading

    func snapshot() -> MusicSnapshot {
        let player = player
        let item = player.nowPlayingItem
        var key: String?
        if let item {
            let store = item.playbackStoreID
            key = store.isEmpty || store == "0" ? String(item.persistentID) : store
        }
        var title = item?.title
        var artist = item?.artist
        if item != nil, title?.isEmpty ?? true {
            // Some catalog items reach MediaPlayer without names; MusicKit's view of the same player has them.
            if let entry = MusicKit.SystemMusicPlayer.shared.queue.currentEntry {
                title = entry.title
                artist = artist ?? entry.subtitle
            }
        }
        return MusicSnapshot(state: player.playbackState, rate: player.currentPlaybackRate,
                             time: player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0,
                             itemKey: key, title: Self.nonEmpty(title), artist: Self.nonEmpty(artist),
                             album: Self.nonEmpty(item?.albumTitle))
    }

    /// Whether some other app is playing while the Music app isn't.
    func otherAppPlaying(musicPlaying: Bool) -> Bool {
        !musicPlaying && AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// True when sound goes to the iPhone's own speaker (no glasses, headphones or car connected for audio).
    var onPhoneSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    // MARK: Starting playback

    /// Queues and plays the first of `queues` that starts, within `budget` seconds. Checks that playback really
    /// started (a fresh item playing), retries once if it didn't, and logs states and timings only.
    func start(_ queues: [MusicQueue], shuffle: Bool, budget: TimeInterval = 11) async -> StartOutcome {
        let started = Date()
        let deadline = started.addingTimeInterval(budget)
        var lastCode: Int?
        var lastDefinitive = false
        log("Music: starting (\(Self.appState), shuffle \(shuffle ? "on" : "off"), \(queues.count) route(s))")

        for (index, queue) in queues.enumerated() {
            guard let descriptor = queue.descriptor else { continue }
            if Task.isCancelled { return .failed(code: nil, definitive: false, cancelled: true) }
            let left = deadline.timeIntervalSinceNow
            guard left > 1.5 else { break }
            let isLast = index == queues.count - 1

            // Attempt 1: queue, prepare, play, watch.
            let before = snapshot()
            let prepared = await queueAndPrepare(descriptor, shuffle: shuffle, timeout: min(3, left - 1))
            if case .failed(let code) = prepared {
                lastCode = code
                lastDefinitive = Self.isDefinitive(code)
                log("Music: \(queue.label) not accepted (code \(code))")
                if lastDefinitive { continue }
            }
            // The call may have been cut off while preparing: never start music after Claude was told it failed.
            if Task.isCancelled { return .failed(code: nil, definitive: false, cancelled: true) }
            player.play()
            if let snap = await waitForPlayback(since: before, seconds: min(2.5, deadline.timeIntervalSinceNow)) {
                log("Music: started via \(queue.label) after \(Self.seconds(since: started)) (attempt 1)")
                return .started(snap, queue: queue)
            }
            if Task.isCancelled { return .failed(code: nil, definitive: false, cancelled: true) }

            // Attempt 2: the queue is in, the play didn't take. Ask again.
            log("Music: not playing after attempt 1 (\(snapshot().stateLabel)); asking again")
            player.play()
            if let snap = await waitForPlayback(since: before, seconds: min(1.5, deadline.timeIntervalSinceNow)) {
                log("Music: started via \(queue.label) after \(Self.seconds(since: started)) (attempt 2)")
                return .started(snap, queue: queue)
            }

            // Attempt 3, last route only: queue it again from scratch.
            if isLast, deadline.timeIntervalSinceNow > 3, !Task.isCancelled {
                log("Music: still \(snapshot().stateLabel); queueing again")
                _ = await queueAndPrepare(descriptor, shuffle: shuffle, timeout: min(2, deadline.timeIntervalSinceNow - 1.5))
                if Task.isCancelled { return .failed(code: nil, definitive: false, cancelled: true) }
                player.play()
                if let snap = await waitForPlayback(since: before, seconds: min(2, deadline.timeIntervalSinceNow)) {
                    log("Music: started via \(queue.label) after \(Self.seconds(since: started)) (attempt 3)")
                    return .started(snap, queue: queue)
                }
            }
            log("Music: \(queue.label) didn't start (\(snapshot().stateLabel))")
        }
        log("Music: playback didn't start after \(Self.seconds(since: started))")
        return .failed(code: lastCode, definitive: lastDefinitive, cancelled: Task.isCancelled)
    }

    private enum Prepared {
        case ready, timedOut, failed(Int)
    }

    private func queueAndPrepare(_ descriptor: MPMusicPlayerQueueDescriptor, shuffle: Bool,
                                 timeout: TimeInterval) async -> Prepared {
        let player = player
        // Set shuffle and repeat explicitly: the Music app's own settings would carry over otherwise.
        player.shuffleMode = shuffle ? .songs : .off
        player.repeatMode = .none
        player.setQueue(with: descriptor)
        player.shuffleMode = shuffle ? .songs : .off
        let begun = Date()
        let result: Prepared = await withCheckedContinuation { continuation in
            let once = MusicOnce()
            player.prepareToPlay { error in
                guard once.fire() else { return }
                continuation.resume(returning: error.map { .failed(($0 as NSError).code) } ?? .ready)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                guard once.fire() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
        switch result {
        case .ready: log("Music: prepared in \(Self.seconds(since: begun))")
        case .timedOut: log("Music: prepare still pending after \(Self.seconds(since: begun)); playing anyway")
        case .failed: break
        }
        return result
    }

    /// Polls until a fresh item plays: the state or rate says playing, or the clock moves, and it isn't simply
    /// the song that was already playing before the new queue.
    private func waitForPlayback(since before: MusicSnapshot, seconds: TimeInterval) async -> MusicSnapshot? {
        let end = Date().addingTimeInterval(max(0.25, seconds))
        var previous = snapshot()
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return nil }
            let now = snapshot()
            let clockMoved = now.itemKey != nil && now.itemKey == previous.itemKey && now.time > previous.time + 0.1
            if (now.looksPlaying || clockMoved), Self.isFresh(now, since: before) {
                return await withName(now)
            }
            previous = now
        }
        return nil
    }

    private static func isFresh(_ now: MusicSnapshot, since before: MusicSnapshot) -> Bool {
        if !before.looksPlaying { return true }
        if now.itemKey != before.itemKey { return true }
        // Same item as before: fresh only if it started over.
        return now.time + 1 < before.time || now.time < 2.5
    }

    /// The title can arrive a moment after playback starts.
    private func withName(_ snap: MusicSnapshot) async -> MusicSnapshot {
        var snap = snap
        var tries = 0
        while snap.title == nil, tries < 4, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            snap = snapshot()
            tries += 1
        }
        return snap
    }

    // MARK: Controls

    func pause() { player.pause() }
    func resume() { player.play() }
    func next() { player.skipToNextItem() }
    func previous() { player.skipToPreviousItem() }
    func restart() { player.skipToBeginning() }
    func setShuffle(_ on: Bool) { player.shuffleMode = on ? .songs : .off }
    func setRepeat(_ mode: MPMusicRepeatMode) { player.repeatMode = mode }

    /// Waits up to `seconds` for `condition`, checking every quarter second. Returns the last snapshot and whether
    /// the condition held.
    func wait(seconds: TimeInterval, until condition: (MusicSnapshot) -> Bool) async -> (MusicSnapshot, Bool) {
        let end = Date().addingTimeInterval(seconds)
        var snap = snapshot()
        while !condition(snap), Date() < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            snap = snapshot()
        }
        return (snap, condition(snap))
    }

    // MARK: Helpers

    // MPErrorDomain codes (MPError.h): 1 permission denied, 2 cloud service capability missing (no subscription),
    // 3 network, 4 not found, 5 not supported, 6 cancelled, 7 timed out.

    /// MediaPlayer errors that retrying won't fix: not allowed, no subscription, not found, not supported.
    private static func isDefinitive(_ code: Int) -> Bool {
        [1, 2, 4, 5].contains(code)
    }

    static func isSubscriptionProblem(_ code: Int?) -> Bool {
        code == 1 || code == 2
    }

    /// "background, locked" — for the day-1 test of starting music with the iPhone locked.
    static var appState: String {
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "foreground"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        return "\(state), \(app.isProtectedDataAvailable ? "unlocked" : "locked")"
    }

    static func seconds(since date: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(date))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
