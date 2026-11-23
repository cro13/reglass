import Foundation
import MusicKit

// MusicKit's names, spelled out so another type with the same name elsewhere in ReGlass can't make this file ambiguous.
private typealias MKSong = MusicKit.Song
private typealias MKAlbum = MusicKit.Album
private typealias MKArtist = MusicKit.Artist
private typealias MKPlaylist = MusicKit.Playlist
private typealias MKStation = MusicKit.Station
private typealias MKTrack = MusicKit.Track

/// Finds music in the Apple Music catalog with MusicKit. MusicKit gets its developer token from Apple only when the
/// MusicKit App Service is enabled for ReGlass's App ID; without it every call here throws
/// `MusicTokenRequestError.developerTokenRequestFailed`, and `MusicService` falls back to the library.
/// Errors are thrown as they come (MusicKit's, or `MusicTimeout`); `MusicService` classifies them.
@MainActor
enum MusicCatalogResolver {
    static func resolve(_ request: MusicRequest) async throws -> MusicPick? {
        let term = request.query
        switch request.kind {
        case .library:
            return nil
        case .song:
            let hits = try await search(term, [.song])
            return hits.songs.first.map(songPick)
        case .artist:
            let hits = try await search(term, [.artist], limit: 3)
            guard let artist = hits.artists.first else { return nil }
            return try await artistPick(artist, preferStation: false)
        case .album:
            return try await albumPick(term, newest: request.newest)
        case .playlist:
            let name = MusicText.playlistName(term)
            // Apple Music's mixes made for the owner ("Discovery Station", "Chill Mix") come first. Both lookups run
            // at once, so a slow connection costs one wait, not two.
            async let mine = recommended(name, playlists: true)
            async let found = search(name, [.playlist])
            if let mine = await mine { return await pick(for: mine) }
            let hits = try await found
            guard let list = hits.playlists.first(where: { MusicText.score($0.name, name) >= 60 }) ?? hits.playlists.first
            else { return nil }
            return await playlistPick(list)
        case .station:
            if isPersonalStation(term), let station = try? await personalStation() {
                return stationPick(station, by: nil)
            }
            async let mine = recommended(term, playlists: false)
            async let found = search(term, [.station, .artist])
            if let mine = await mine { return await pick(for: mine) }
            let hits = try await found
            if let artist = hits.artists.first, MusicText.score(artist.name, term) >= 85,
               let pick = try await artistPick(artist, preferStation: true) {
                return pick
            }
            return hits.stations.first.map { stationPick($0, by: nil) }
        case .any:
            let hits = try await search(term, [.song, .album, .artist, .playlist, .station], top: true)
            for top in hits.top {
                if let pick = try await pick(for: top) { return pick }
            }
            if let artist = hits.artists.first, MusicText.score(artist.name, term) >= 85 {
                return try await artistPick(artist, preferStation: false)
            }
            return hits.songs.first.map(songPick)
        }
    }

    /// A tiny search, for Settings: does the catalog answer at all?
    static func probe() async throws {
        _ = try await search("music", [.song], limit: 1)
    }

    // MARK: Search

    private enum SearchType: Sendable {
        case song, album, artist, playlist, station

        var type: any MusicCatalogSearchable.Type {
            switch self {
            case .song: return MKSong.self
            case .album: return MKAlbum.self
            case .artist: return MKArtist.self
            case .playlist: return MKPlaylist.self
            case .station: return MKStation.self
            }
        }
    }

    private struct Hits: Sendable {
        var top: [MusicCatalogSearchResponse.TopResult] = []
        var songs: [MKSong] = []
        var albums: [MKAlbum] = []
        var artists: [MKArtist] = []
        var playlists: [MKPlaylist] = []
        var stations: [MKStation] = []
    }

    private static func search(_ term: String, _ types: [SearchType], limit: Int = 5, top: Bool = false) async throws -> Hits {
        try await musicWithTimeout(5) {
            var request = MusicCatalogSearchRequest(term: term, types: types.map(\.type))
            request.limit = limit
            request.includeTopResults = top
            let response = try await request.response()
            return Hits(top: Array(response.topResults), songs: Array(response.songs), albums: Array(response.albums),
                        artists: Array(response.artists), playlists: Array(response.playlists),
                        stations: Array(response.stations))
        }
    }

    private static func pick(for top: MusicCatalogSearchResponse.TopResult) async throws -> MusicPick? {
        switch top {
        case .song(let song): return songPick(song)
        case .album(let album): return await albumPick(album)
        case .artist(let artist): return try await artistPick(artist, preferStation: false)
        case .playlist(let list): return await playlistPick(list)
        case .station(let station): return stationPick(station, by: nil)
        default: return nil
        }
    }

    // MARK: Picks

    private static func songPick(_ song: MKSong) -> MusicPick {
        MusicPick(kind: .song, source: .catalog, name: song.title, by: song.artistName, songCount: 1,
                  defaultShuffle: false, queues: songQueues([song]))
    }

    /// An artist's top songs (shuffled unless asked otherwise), with their station as the fallback; or the station
    /// first for "Rihanna radio".
    private static func artistPick(_ artist: MKArtist, preferStation: Bool) async throws -> MusicPick? {
        let detailed = try await musicWithTimeout(4) { try await artist.with([.topSongs, .station]) }
        var songs = Array(detailed.topSongs ?? [])
        if !preferStation, songs.count < 15, let batch = detailed.topSongs, batch.hasNextBatch {
            let more = try? await musicWithTimeout(2) { Array(try await batch.nextBatch(limit: 20) ?? []) }
            songs += more ?? []
        }
        let station = detailed.station.map { stationPick($0, by: artist.name) }
        let topSongs = songs.isEmpty ? nil : MusicPick(kind: .artistSongs, source: .catalog, name: artist.name, by: nil,
                                                       songCount: songs.count, defaultShuffle: true,
                                                       queues: songQueues(songs))
        if preferStation, var station {
            station.alternatives = topSongs.map { [$0] } ?? []
            return station
        }
        if var topSongs {
            topSongs.alternatives = station.map { [$0] } ?? []
            return topSongs
        }
        return station
    }

    private static func albumPick(_ term: String, newest: Bool) async throws -> MusicPick? {
        guard newest else {
            let hits = try await search(term, [.album])
            guard let album = hits.albums.first else { return nil }
            return await albumPick(album)
        }
        // "The new Taylor Swift album": the artist's newest full album, or a newer non-single release.
        let hits = try await search(term, [.artist, .album])
        if let artist = hits.artists.first, MusicText.score(artist.name, term) >= 60 {
            let detailed = try await musicWithTimeout(4) { try await artist.with([.fullAlbums, .latestRelease]) }
            var album = Array(detailed.fullAlbums ?? []).max { released($0) < released($1) }
            if let latest = detailed.latestRelease, latest.isSingle != true,
               released(latest) > (album.map(released) ?? .distantPast) {
                album = latest
            }
            if let album = album ?? detailed.latestRelease { return await albumPick(album) }
        }
        guard let album = hits.albums.max(by: { released($0) < released($1) }) else { return nil }
        return await albumPick(album)
    }

    private static func albumPick(_ album: MKAlbum) async -> MusicPick {
        let tracks = await trackIDs { try await album.with([.tracks]).tracks }
        return MusicPick(kind: .album, source: .catalog, name: album.title, by: album.artistName,
                         songCount: album.trackCount > 0 ? album.trackCount : nil, defaultShuffle: false,
                         queues: itemQueues(album.playParameters, id: album.id, tracks: tracks))
    }

    private static func playlistPick(_ list: MKPlaylist) async -> MusicPick {
        let tracks = await trackIDs { try await list.with([.tracks]).tracks }
        return MusicPick(kind: .playlist, source: .catalog, name: list.name, by: list.curatorName,
                         songCount: tracks.isEmpty ? nil : tracks.count, defaultShuffle: false,
                         queues: itemQueues(list.playParameters, id: list.id, tracks: tracks))
    }

    private static func stationPick(_ station: MKStation, by: String?) -> MusicPick {
        MusicPick(kind: .station, source: .catalog, name: station.name, by: by, songCount: nil, defaultShuffle: false,
                  queues: itemQueues(station.playParameters, id: station.id, tracks: []))
    }

    // MARK: Queues

    /// Songs by store ID (the long-proven route), then by play parameters.
    private static func songQueues(_ songs: [MKSong]) -> [MusicQueue] {
        var queues: [MusicQueue] = [.storeIDs(songs.map(\.id.rawValue))]
        let parameters = songs.compactMap(\.playParameters)
        if !parameters.isEmpty { queues.append(.playParameters(parameters)) }
        return queues
    }

    /// An album, playlist or station by play parameters (keeps "Playing from …" in the Music app), then its tracks
    /// by store ID, then its own ID.
    private static func itemQueues(_ parameters: MusicKit.PlayParameters?, id: MusicKit.MusicItemID,
                                   tracks: [String]) -> [MusicQueue] {
        var queues: [MusicQueue] = []
        if let parameters { queues.append(.playParameters([parameters])) }
        if !tracks.isEmpty { queues.append(.storeIDs(tracks)) }
        queues.append(.storeIDs([id.rawValue]))
        return queues
    }

    private static func trackIDs(_ load: @escaping @Sendable () async throws -> MusicItemCollection<MKTrack>?) async -> [String] {
        let tracks = try? await musicWithTimeout(3) { Array(try await load() ?? []) }
        return (tracks ?? []).map(\.id.rawValue)
    }

    private static func released(_ album: MKAlbum) -> Date {
        album.releaseDate ?? .distantPast
    }

    // MARK: Made for the owner

    private struct Recommended: Sendable {
        var playlists: [MKPlaylist]
        var stations: [MKStation]
    }

    private static var recommendedCache: (date: Date, value: Recommended)?

    private enum RecommendedItem: Sendable {
        case playlist(MKPlaylist)
        case station(MKStation)
    }

    private static func pick(for item: RecommendedItem) async -> MusicPick {
        switch item {
        case .playlist(let list): return await playlistPick(list)
        case .station(let station): return stationPick(station, by: nil)
        }
    }

    /// A mix or station Apple Music made for the owner whose name matches ("Discover" → "Discovery Station").
    private static func recommended(_ name: String, playlists: Bool) async -> RecommendedItem? {
        guard let mine = await recommendations() else { return nil }
        var bestList: (MKPlaylist, Int)?
        var bestStation: (MKStation, Int)?
        if playlists {
            for list in mine.playlists {
                let score = MusicText.score(list.name, name)
                if score > (bestList?.1 ?? 0) { bestList = (list, score) }
            }
        }
        for station in mine.stations {
            let score = MusicText.score(station.name, name)
            if score > (bestStation?.1 ?? 0) { bestStation = (station, score) }
        }
        let listScore = bestList?.1 ?? 0
        let stationScore = bestStation?.1 ?? 0
        guard max(listScore, stationScore) >= 75 else { return nil }
        if let (list, _) = bestList, listScore >= stationScore { return .playlist(list) }
        return bestStation.map { .station($0.0) }
    }

    private static func recommendations() async -> Recommended? {
        if let cache = recommendedCache, Date().timeIntervalSince(cache.date) < 30 * 60 { return cache.value }
        let fresh = try? await musicWithTimeout(3) {
            let response = try await MusicPersonalRecommendationsRequest().response()
            var value = Recommended(playlists: [], stations: [])
            for recommendation in response.recommendations {
                value.playlists += Array(recommendation.playlists)
                value.stations += Array(recommendation.stations)
            }
            return value
        }
        if let fresh { recommendedCache = (Date(), fresh) }
        return fresh
    }

    private static func isPersonalStation(_ term: String) -> Bool {
        let phrases: Set<String> = ["my station", "personal station", "my personal station", "my radio", "for me",
                                    "station for me", "me", "personal", "my own station"]
        return phrases.contains(MusicText.normalize(term))
    }

    /// The owner's personal station, from the Apple Music API.
    private static func personalStation() async throws -> MKStation? {
        try await musicWithTimeout(4) {
            let country = try await MusicDataRequest.currentCountryCode
            guard var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(country)/stations")
            else { return nil }
            components.queryItems = [URLQueryItem(name: "filter[identity]", value: "personal")]
            guard let url = components.url else { return nil }
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            struct Body: Decodable { let data: [MusicKit.Station] }
            return try JSONDecoder().decode(Body.self, from: response.data).data.first
        }
    }
}
