import CryptoKit
import Foundation

public enum SpotifyPKCE {
    private static let verifierBytes = 48

    public static func makeVerifier() -> String {
        verifier(bytes: randomBytes(verifierBytes))
    }

    public static func makeState() -> String {
        verifier(bytes: randomBytes(16))
    }

    static func verifier(bytes: [UInt8]) -> String {
        base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct SpotifyToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public func needsRefresh(now: Date = Date(), skew: TimeInterval = SpotifyAuth.expirySkew) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}

public enum SpotifyAuthError: Error, Equatable, Sendable {
    case rejected(code: String, description: String)
    case missingRefreshToken
    case malformed
}

public enum SpotifyAuth {
    public static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    public static let redirectPort: UInt16 = 43821
    public static let redirectPath = "/callback"
    public static let redirectURI = URL(string: "http://127.0.0.1:\(redirectPort)\(redirectPath)")!

    public static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-read-playback-state",
        "user-modify-playback-state",
    ]

    public static let expirySkew: TimeInterval = 60

    public static func authorizationURL(clientID: String, redirectURI: URL, state: String, challenge: String, scopes: [String]) -> URL {
        var parts = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    public static func tokenExchangeRequest(code: String, verifier: String, clientID: String, redirectURI: URL) -> URLRequest {
        formPost([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
    }

    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formPost([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
    }

    public static func token(from data: Data, now: Date, previous: SpotifyToken?) throws -> SpotifyToken {
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(ErrorBody.self, from: data) {
            throw SpotifyAuthError.rejected(code: failure.error, description: failure.errorDescription ?? "")
        }
        guard let body = try? decoder.decode(TokenBody.self, from: data) else { throw SpotifyAuthError.malformed }
        guard let refresh = body.refreshToken ?? previous?.refreshToken else { throw SpotifyAuthError.missingRefreshToken }
        return SpotifyToken(
            accessToken: body.accessToken,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(TimeInterval(body.expiresIn)),
            scope: body.scope ?? previous?.scope ?? ""
        )
    }

    private struct TokenBody: Decodable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?
        var scope: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct ErrorBody: Decodable {
        var error: String
        var errorDescription: String?

        private enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    private static func formPost(_ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }
}

public enum SpotifyCallback: Equatable, Sendable {
    case code(String)
    case denied(String)

    public static func requestTarget(fromHead head: String) -> String? {
        guard let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/") else { return nil }
        return String(parts[1])
    }

    public static func parse(target: String, path: String, state expected: String) throws -> SpotifyCallback {
        guard let parts = URLComponents(string: target), parts.path == path else { throw SpotifyCallbackError.notCallback }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["state"] == expected else { throw SpotifyCallbackError.stateMismatch }
        if let error = query["error"], !error.isEmpty { return .denied(error) }
        guard let code = query["code"], !code.isEmpty else { throw SpotifyCallbackError.missingCode }
        return .code(code)
    }
}

public enum SpotifyCallbackError: Error, Equatable, Sendable {
    case notCallback, stateMismatch, missingCode
}
