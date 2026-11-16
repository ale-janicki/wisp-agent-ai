import Foundation

public enum SpotifyPlay: Equatable, Sendable {
    case context(String, startAt: String? = nil)
    case tracks([String])
}

public enum SpotifyEndpoint: Equatable, Sendable {
    case myPlaylists(limit: Int, offset: Int)
    case playlistItems(id: String, limit: Int, offset: Int)
    case search(query: String, limit: Int)
    case devices
    case play(SpotifyPlay, deviceID: String?)
    case queue(uri: String, deviceID: String?)

    public static let base = URL(string: "https://api.spotify.com/v1")!
    public static let searchLimitMax = 10
    public static let pageLimitMax = 50
    public static let searchTypes = "track,album,playlist,artist"

    public var isPlayer: Bool {
        switch self {
        case .play, .queue: true
        default: false
        }
    }

    public func urlRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private var method: String {
        switch self {
        case .myPlaylists, .playlistItems, .search, .devices: "GET"
        case .play: "PUT"
        case .queue: "POST"
        }
    }

    private var url: URL {
        switch self {
        case .myPlaylists(let limit, let offset):
            Self.url("me/playlists", [("limit", "\(Self.page(limit))"), ("offset", "\(max(0, offset))")])
        case .playlistItems(let id, let limit, let offset):
            Self.url("playlists/\(Self.segment(id))/items", [("limit", "\(Self.page(limit))"), ("offset", "\(max(0, offset))")])
        case .search(let query, let limit):
            Self.url("search", [("q", query), ("type", Self.searchTypes), ("limit", "\(min(max(1, limit), Self.searchLimitMax))")])
        case .devices:
            Self.url("me/player/devices", [])
        case .play(_, let deviceID):
            Self.url("me/player/play", deviceID.map { [("device_id", $0)] } ?? [])
        case .queue(let uri, let deviceID):
            Self.url("me/player/queue", [("uri", uri)] + (deviceID.map { [("device_id", $0)] } ?? []))
        }
    }

    private var body: Data? {
        guard case .play(let play, _) = self else { return nil }
        let object: [String: Any]
        switch play {
        case .context(let uri, let start):
            var context: [String: Any] = ["context_uri": uri]
            if let start { context["offset"] = ["uri": start] }
            object = context
        case .tracks(let uris):
            object = ["uris": uris]
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func page(_ limit: Int) -> Int { min(max(1, limit), pageLimitMax) }

    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    private static func url(_ path: String, _ query: [(String, String)]) -> URL {
        let encoded = query.map { "\($0.0)=\(segment($0.1))" }.joined(separator: "&")
        let string = base.absoluteString + "/" + path + (encoded.isEmpty ? "" : "?" + encoded)
        return URL(string: string)!
    }
}

public enum SpotifyFailure: Error, Equatable, Sendable {
    case unauthorized
    case premiumRequired
    case noActiveDevice
    case forbidden(String)
    case notFound(String)
    case rateLimited(retryAfter: TimeInterval, quota: Bool)
    case server(status: Int, message: String)

    public static func classify(status: Int, body: Data, retryAfter: String?, player: Bool) -> SpotifyFailure? {
        guard !(200..<300).contains(status) else { return nil }
        let error = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
        let message = error?.message ?? ""
        let reason = error?.reason?.uppercased() ?? ""
        switch status {
        case 401:
            return .unauthorized
        case 403 where player && (reason == "PREMIUM_REQUIRED" || message.lowercased().contains("premium")):
            return .premiumRequired
        case 403:
            return .forbidden(message)
        case 404 where player:
            return .noActiveDevice
        case 404:
            return .notFound(message)
        case 429:
            let seconds = retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.map { max(1, $0) } ?? 1
            return .rateLimited(retryAfter: seconds, quota: reason == "QUOTA_EXCEEDED")
        default:
            return .server(status: status, message: message)
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            var message: String?
            var reason: String?
        }
        var error: Detail
    }
}
