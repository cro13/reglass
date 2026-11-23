import Foundation
import ReGlassAssistant

// Shared pieces for the Apple Music connector: what Claude asked for, fuzzy name matching, and a timeout for
// network calls, so a tool never hangs on a slow connection.

/// What the owner asked to play, after checking Claude's input.
struct MusicRequest: Equatable {
    enum Kind: String, CaseIterable {
        case any, song, artist, album, playlist, station, library
    }

    /// Cleaned up: "Rihanna", "Discover", "calm". Empty means everything (the whole library).
    var query: String
    var kind: Kind
    /// Nil: the pick's own default (artists and the whole library shuffle; albums and playlists play in order).
    var shuffle: Bool?
    /// The artist's newest release ("the new Taylor Swift album").
    var newest: Bool

    /// Reads Claude's arguments. Returns nil with a sentence for Claude when they can't be used.
    static func parse(_ input: JSONValue) -> (request: MusicRequest?, problem: String?) {
        guard input.object != nil else { return (nil, "The input must be an object with a query.") }
        var query = (input["query"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if query.count > 200 { query = String(query.prefix(200)) }

        var kind = Kind.any
        if let raw = input["kind"]?.string?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            switch raw {
            case "track", "songs": kind = .song
            case "artists", "band", "singer": kind = .artist
            case "albums", "record", "ep": kind = .album
            case "playlists", "mix", "mood", "genre": kind = .playlist
            case "radio", "stations": kind = .station
            case "my library", "my music", "songs in my library": kind = .library
            default: kind = Kind(rawValue: raw) ?? .any
            }
        }

        var newest = Self.flag(input["newest"]) ?? false
        // "new Taylor Swift album" sometimes arrives as one query: lift the "new" out of it. Only when the words say
        // album (or latest/newest), so a title like "New Rules" stays as it is.
        if kind == .album || kind == .any {
            let words = query.split(separator: " ").map { $0.lowercased() }
            let markers: Set<String> = ["new", "newest", "latest", "recent"]
            let saysAlbum = words.contains("album") || words.contains("latest") || words.contains("newest")
            if saysAlbum, words.contains(where: markers.contains) {
                let rest = query.split(separator: " ").map(String.init).filter {
                    !markers.contains($0.lowercased()) && !["album", "the", "release", "record"].contains($0.lowercased())
                }
                if !rest.isEmpty {
                    newest = true
                    query = rest.joined(separator: " ")
                    kind = .album
                }
            }
        }

        if MusicText.meansWholeLibrary(query) {
            query = ""
            if kind == .any { kind = .library }
        }
        // Nothing named: play the owner's own music.
        if query.isEmpty, kind != .library { kind = .library }
        return (MusicRequest(query: query, kind: kind, shuffle: Self.flag(input["shuffle"]), newest: newest), nil)
    }

    private static func flag(_ value: JSONValue?) -> Bool? {
        if let bool = value?.bool { return bool }
        switch value?.string?.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }
}

enum MusicText {
    /// Lowercased, without accents or punctuation, single spaces: "Beyoncé – Halo!" → "beyonce halo".
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let letters = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// How well a name matches what was asked, 0...100. 85 or more is a confident match.
    static func score(_ name: String, _ query: String) -> Int {
        let n = normalize(name)
        let q = normalize(query)
        guard !n.isEmpty, !q.isEmpty else { return 0 }
        if n == q { return 100 }
        // One or two letters only match exactly.
        guard q.count >= 3 else { return 0 }
        if n.hasPrefix(q) { return 85 }
        if (" " + n).contains(" " + q) { return 75 }
        if n.count >= 4, (" " + q + " ").contains(" " + n + " ") { return 65 }
        let nameWords = Set(n.split(separator: " "))
        let queryWords = Set(q.split(separator: " "))
        let common = nameWords.intersection(queryWords).count
        return common == 0 ? 0 : 50 * common / max(queryWords.count, 1)
    }

    /// A playlist request without the words around the name: "my Discover playlist" → "Discover".
    static func playlistName(_ query: String) -> String {
        let filler: Set<String> = ["my", "the", "playlist", "playlists", "a"]
        let words = query.split(separator: " ").filter { !filler.contains($0.lowercased()) }
        return words.isEmpty ? query : words.joined(separator: " ")
    }

    static func meansWholeLibrary(_ query: String) -> Bool {
        let all: Set<String> = ["", "library", "my library", "my music", "music", "all", "everything", "all my music",
                                "my songs", "all songs", "all my songs", "songs", "my whole library", "whole library",
                                "the library", "my collection", "anything", "something"]
        return all.contains(normalize(query))
    }
}

struct MusicTimeout: Error {}

/// Runs `operation`, giving up after `seconds` or when the caller is cancelled. Returns at the deadline even if the
/// operation ignores cancellation (a stuck network request keeps running on its own and is then ignored), which a
/// task group can't do: it always waits for its children.
func musicWithTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = MusicRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, seconds: seconds, operation: operation)
        }
    } onCancel: {
        race.cancel()
    }
}

/// The first of the operation, the deadline or a cancellation to finish wins; the others are ignored.
private final class MusicRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<T, Error>, seconds: Double,
               operation: @escaping @Sendable () async throws -> T) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let work = Task {
            do {
                self.finish(.success(try await operation()))
            } catch {
                self.finish(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.finish(.failure(MusicTimeout()))
        }
        lock.lock()
        tasks = [work, timer]
        let done = self.continuation == nil
        lock.unlock()
        if done { work.cancel(); timer.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}

/// Fires once: for racing a completion handler against a deadline on the main queue.
final class MusicOnce: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    func fire() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
