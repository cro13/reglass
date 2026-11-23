import Foundation
import MediaPlayer

/// Finds music in the owner's own library (songs, albums and playlists on this iPhone and in their synced iCloud
/// library) through MediaPlayer. Needs only the Apple Music permission: no Apple Music catalog access, so it works
/// before MusicKit is set up for ReGlass, without a subscription, and offline for downloaded songs.
@MainActor
enum MusicLibraryLookup {
    /// The best library match for `request`, or nil.
    static func resolve(_ request: MusicRequest) -> MusicPick? {
        let query = request.query
        switch request.kind {
        case .library:
            return query.isEmpty ? wholeLibrary() : anything(query)
        case .playlist:
            return playlist(query, minimum: 50)
        case .artist, .station:
            return artist(query).flatMap { $0.score >= 50 ? $0.pick : nil }
        case .album:
            if request.newest, let newest = newestAlbum(query) { return newest }
            return album(query).flatMap { $0.score >= 50 ? $0.pick : nil }
        case .song:
            return song(query).flatMap { $0.score >= 60 ? $0.pick : nil }
        case .any:
            return anything(query)
        }
    }

    /// A library playlist whose name matches at least `minimum` (see `MusicText.score`).
    static func playlist(_ query: String, minimum: Int) -> MusicPick? {
        playlistMatch(query).flatMap { $0.score >= minimum ? $0.pick : nil }
    }

    // MARK: Private

    private typealias Match = (pick: MusicPick, score: Int)

    private static func wholeLibrary() -> MusicPick? {
        let songs = MPMediaQuery.songs()
        let count = songs.items?.count ?? 0
        guard count > 0 else { return nil }
        return MusicPick(kind: .librarySongs, source: .library, name: "your library", by: nil, songCount: count,
                         defaultShuffle: true, queues: [.libraryQuery(songs)])
    }

    /// A confident match in the order playlist, artist, album, song; otherwise the best decent one.
    private static func anything(_ query: String) -> MusicPick? {
        let matches = [playlistMatch(query), artist(query), album(query), song(query)].compactMap { $0 }
        if let strong = matches.first(where: { $0.score >= ($0.pick.kind == .song ? 75 : 85) }) { return strong.pick }
        return matches.filter { $0.score >= 60 }.max { $0.score < $1.score }?.pick
    }

    private static func playlistMatch(_ query: String) -> Match? {
        let name = MusicText.playlistName(query)
        let playlists = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist] ?? []).filter { $0.count > 0 }
        let scored = playlists.map { ($0, MusicText.score($0.name ?? "", name)) }
        guard let (best, score) = scored.max(by: { $0.1 < $1.1 }), score > 0 else { return nil }
        return (MusicPick(kind: .playlist, source: .library, name: best.name ?? "Playlist", by: nil,
                          songCount: best.count, defaultShuffle: false, queues: [.libraryItems(best)]), score)
    }

    private static func artist(_ query: String) -> Match? {
        guard let (item, name, score) = bestArtist(query) else { return nil }
        let songs = songsQuery(byArtist: item)
        let count = songs.items?.count ?? 0
        guard count > 0 else { return nil }
        return (MusicPick(kind: .artistSongs, source: .library, name: name, by: nil, songCount: count,
                          defaultShuffle: true, queues: [.libraryQuery(songs)]), score)
    }

    private static func bestArtist(_ query: String) -> (MPMediaItem, String, Int)? {
        var best: (MPMediaItem, String, Int)?
        for collection in MPMediaQuery.artists().collections ?? [] {
            guard let item = collection.representativeItem, let name = item.artist ?? item.albumArtist else { continue }
            let score = MusicText.score(name, query)
            if score > (best?.2 ?? 0) { best = (item, name, score) }
        }
        return best
    }

    private static func songsQuery(byArtist item: MPMediaItem) -> MPMediaQuery {
        let songs = MPMediaQuery.songs()
        songs.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.artistPersistentID),
                                                          forProperty: MPMediaItemPropertyArtistPersistentID))
        return songs
    }

    private static func album(_ query: String) -> Match? {
        let scored = (MPMediaQuery.albums().collections ?? []).map {
            ($0, MusicText.score($0.representativeItem?.albumTitle ?? "", query))
        }
        guard let (best, score) = scored.max(by: { $0.1 < $1.1 }), score > 0, let pick = albumPick(best) else { return nil }
        return (pick, score)
    }

    /// The artist's most recent album in the library ("the new Taylor Swift album" when the catalog can't help).
    private static func newestAlbum(_ query: String) -> MusicPick? {
        guard let (item, _, score) = bestArtist(query), score >= 65 else { return nil }
        let albums = MPMediaQuery.albums()
        albums.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: item.artistPersistentID),
                                                           forProperty: MPMediaItemPropertyArtistPersistentID))
        let newest = (albums.collections ?? []).max {
            ($0.representativeItem?.releaseDate ?? .distantPast) < ($1.representativeItem?.releaseDate ?? .distantPast)
        }
        return newest.flatMap(albumPick)
    }

    private static func albumPick(_ collection: MPMediaItemCollection) -> MusicPick? {
        guard collection.count > 0, let item = collection.representativeItem else { return nil }
        return MusicPick(kind: .album, source: .library, name: item.albumTitle ?? "Album",
                         by: item.albumArtist ?? item.artist, songCount: collection.count, defaultShuffle: false,
                         queues: [.libraryItems(collection)])
    }

    /// A song by title, or by title and artist ("Diamonds Rihanna").
    private static func song(_ query: String) -> Match? {
        var best: (MPMediaItem, Int)?
        for item in MPMediaQuery.songs().items ?? [] {
            let title = item.title ?? ""
            let score = max(MusicText.score(title, query), MusicText.score(title + " " + (item.artist ?? ""), query))
            if score > (best?.1 ?? 0) {
                best = (item, score)
                if score == 100 { break }
            }
        }
        guard let (item, score) = best else { return nil }
        return (MusicPick(kind: .song, source: .library, name: item.title ?? "Song", by: item.artist, songCount: 1,
                          defaultShuffle: false, queues: [.libraryItems(MPMediaItemCollection(items: [item]))]), score)
    }
}
