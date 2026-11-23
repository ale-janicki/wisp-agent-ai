import Foundation

/// The OAuth "Desktop app" client the user creates in Google Cloud Console (the `credentials.json` download).
public struct GoogleClient: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public enum ParseError: Error, Equatable, Sendable {
        case notJSON
        case webClient
        case missingFields
    }

    /// Reads `{"installed": {"client_id": ..., "client_secret": ...}}`. A `web` client has no loopback flow, so it is refused by name.
    public static func parse(_ data: Data) throws -> GoogleClient {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        guard let installed = root["installed"] as? [String: Any] else {
            throw root["web"] != nil ? ParseError.webClient : ParseError.missingFields
        }
        guard let id = (installed["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let secret = (installed["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
        else { throw ParseError.missingFields }
        return GoogleClient(clientID: id, clientSecret: secret)
    }

    /// The JSON kept in the Keychain: just what the flow needs, in the same `installed` shape the file has.
    public func serialized() -> Data {
        let body: [String: Any] = ["installed": ["client_id": clientID, "client_secret": clientSecret]]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

public struct GoogleToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, email: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.email = email
    }

    public func needsRefresh(now: Date = Date(), skew: TimeInterval = GoogleAuth.expirySkew) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}

public enum GoogleAuthError: Error, Equatable, Sendable {
    case rejected(code: String, description: String)
    case missingRefreshToken
    case missingEmail
    case malformed
}

public enum GoogleAuth {
    public static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// `calendar.events` is enough to read and patch events on the user's calendars; `openid email` only names the account.
    public static let scopes = ["https://www.googleapis.com/auth/calendar.events", "openid", "email"]
    public static let redirectPath = "/callback"
    public static let expirySkew: TimeInterval = 60

    public static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(redirectPath)")!
    }

    /// A random port in the dynamic range, so two Wisp logins or another app never fight over a fixed one.
    public static func randomPort() -> UInt16 {
        UInt16.random(in: 49_152...65_000)
    }

    public static func authorizationURL(clientID: String, redirectURI: URL, state: String, challenge: String) -> URL {
        var parts = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    public static func tokenExchangeRequest(code: String, verifier: String, client: GoogleClient, redirectURI: URL) -> URLRequest {
        formPost(tokenEndpoint, [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("code_verifier", verifier),
        ])
    }

    public static func refreshRequest(refreshToken: String, client: GoogleClient) -> URLRequest {
        formPost(tokenEndpoint, [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
        ])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        formPost(revokeEndpoint, [("token", token)])
    }

    /// Reads a token response. The email comes from the `id_token` Google returns over TLS from its own endpoint (no signature check needed here);
    /// a refresh answer has no `id_token`, so it keeps the previous email.
    public static func token(from data: Data, now: Date, previous: GoogleToken?) throws -> GoogleToken {
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(ErrorBody.self, from: data) {
            throw GoogleAuthError.rejected(code: failure.error, description: failure.errorDescription ?? "")
        }
        guard let body = try? decoder.decode(TokenBody.self, from: data) else { throw GoogleAuthError.malformed }
        guard let refresh = body.refreshToken ?? previous?.refreshToken else { throw GoogleAuthError.missingRefreshToken }
        guard let email = body.idToken.flatMap(email(fromIDToken:)) ?? previous?.email else { throw GoogleAuthError.missingEmail }
        return GoogleToken(accessToken: body.accessToken, refreshToken: refresh, expiresAt: now.addingTimeInterval(TimeInterval(body.expiresIn)), email: email.lowercased())
    }

    public static func email(fromIDToken token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = claims["email"] as? String, email.contains("@") else { return nil }
        return email
    }

    private struct TokenBody: Decodable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?
        var idToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
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

    private static func formPost(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }
}
