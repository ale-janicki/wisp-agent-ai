import Foundation

public struct SpotifyImage: Decodable, Hashable, Sendable {
    public var url: URL
    public var width: Int?
    public var height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

public extension Array where Element == SpotifyImage {
    func best(forPixels pixels: Int) -> URL? {
        let sized = filter { $0.width != nil }.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        if let fit = sized.first(where: { ($0.width ?? 0) >= pixels }) { return fit.url }
        return sized.last?.url ?? first?.url
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

public struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Item]
    public var total: Int
    public var limit: Int
    public var offset: Int
    public var next: String?

    public var hasMore: Bool { next != nil }

    private enum CodingKeys: String, CodingKey { case items, total, limit, offset, next }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([Lossy<Item>].self, forKey: .items) ?? []).compactMap(\.value)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? items.count
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? items.count
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        next = try container.decodeIfPresent(String.self, forKey: .next)
    }
}

private struct Total: Decodable {
    var total: Int?
}

public struct SpotifyArtistRef: Decodable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var uri: String?
}

public struct SpotifyPlaylist: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var uri: String
    public var images: [SpotifyImage]
    public var ownerName: String?
    public var ownerID: String?
    public var trackCount: Int?
    public var collaborative: Bool

    private enum CodingKeys: String, CodingKey { case id, name, uri, images, owner, items, tracks, collaborative }
    private struct Owner: Decodable {
        var id: String?
        var displayName: String?
        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        images = (try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)) ?? []
        let owner = try? container.decodeIfPresent(Owner.self, forKey: .owner)
        ownerName = owner?.displayName
        ownerID = owner?.id
        let items = try? container.decodeIfPresent(Total.self, forKey: .items)
        let tracks = try? container.decodeIfPresent(Total.self, forKey: .tracks)
        trackCount = items?.total ?? tracks?.total
        collaborative = (try? container.decodeIfPresent(Bool.self, forKey: .collaborative)) ?? false
    }
}

public struct SpotifyAlbum: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var uri: String
    public var images: [SpotifyImage]
    public var artists: [SpotifyArtistRef]
    public var totalTracks: Int?

    public var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    private enum CodingKeys: String, CodingKey {
        case id, name, uri, images, artists
        case totalTracks = "total_tracks"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        images = (try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)) ?? []
        artists = (try? container.decodeIfPresent([SpotifyArtistRef].self, forKey: .artists)) ?? []
        totalTracks = try? container.decodeIfPresent(Int.self, forKey: .totalTracks)
    }
}

public struct SpotifyTrack: Decodable, Identifiable, Hashable, Sendable {
    public var trackID: String?
    public var name: String
    public var uri: String
    public var durationMs: Int
    public var artists: [SpotifyArtistRef]
    public var album: SpotifyAlbum?
    public var images: [SpotifyImage]

    public var id: String { uri }
    public var artistLine: String { artists.map(\.name).joined(separator: ", ") }
    public var artwork: [SpotifyImage] { album?.images ?? images }

    private enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, album, images
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        durationMs = (try? container.decodeIfPresent(Int.self, forKey: .durationMs)) ?? 0
        artists = (try? container.decodeIfPresent([SpotifyArtistRef].self, forKey: .artists)) ?? []
        album = try? container.decodeIfPresent(SpotifyAlbum.self, forKey: .album)
        images = (try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)) ?? []
    }
}

public struct SpotifyArtist: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var uri: String
    public var images: [SpotifyImage]

    private enum CodingKeys: String, CodingKey { case id, name, uri, images }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        images = (try? container.decodeIfPresent([SpotifyImage].self, forKey: .images)) ?? []
    }
}

public struct SpotifyPlaylistEntry: Decodable, Sendable {
    public var track: SpotifyTrack?

    private enum CodingKeys: String, CodingKey { case item, track }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = (try? container.decodeIfPresent(SpotifyTrack.self, forKey: .item))
            ?? (try? container.decodeIfPresent(SpotifyTrack.self, forKey: .track))
    }
}

public struct SpotifySearchResults: Decodable, Sendable, Equatable {
    public var tracks: [SpotifyTrack]
    public var albums: [SpotifyAlbum]
    public var playlists: [SpotifyPlaylist]
    public var artists: [SpotifyArtist]

    public var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty }

    private enum CodingKeys: String, CodingKey { case tracks, albums, playlists, artists }

    public init(tracks: [SpotifyTrack] = [], albums: [SpotifyAlbum] = [], playlists: [SpotifyPlaylist] = [], artists: [SpotifyArtist] = []) {
        self.tracks = tracks
        self.albums = albums
        self.playlists = playlists
        self.artists = artists
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = (try? container.decodeIfPresent(SpotifyPage<SpotifyTrack>.self, forKey: .tracks))?.items ?? []
        albums = (try? container.decodeIfPresent(SpotifyPage<SpotifyAlbum>.self, forKey: .albums))?.items ?? []
        playlists = (try? container.decodeIfPresent(SpotifyPage<SpotifyPlaylist>.self, forKey: .playlists))?.items ?? []
        artists = (try? container.decodeIfPresent(SpotifyPage<SpotifyArtist>.self, forKey: .artists))?.items ?? []
    }
}

public struct SpotifyDevice: Decodable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var type: String
    public var isActive: Bool
    public var isRestricted: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isRestricted = "is_restricted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isRestricted = try container.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
    }

    public static func parseList(_ data: Data) throws -> [SpotifyDevice] {
        struct Body: Decodable { var devices: [SpotifyDevice] }
        return try JSONDecoder().decode(Body.self, from: data).devices
    }

    public static func pick(_ devices: [SpotifyDevice]) -> SpotifyDevice? {
        let usable = devices.filter { $0.id != nil && !$0.isRestricted }
        return usable.first(where: \.isActive)
            ?? usable.first { $0.type.lowercased() == "computer" }
            ?? usable.first
    }
}
