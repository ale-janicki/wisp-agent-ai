import Foundation
import WispCore

/// Token life for the connected Google accounts: sign-in exchange, refresh on demand, revoke on disconnect.
actor GoogleSession {
    static let shared = GoogleSession()

    private let transport: any GoogleTransport = URLSessionGoogleTransport()
    private var refreshing: [String: Task<GoogleToken, Error>] = [:]

    func signIn(code: String, verifier: String, redirectURI: URL) async throws -> GoogleToken {
        guard let client = GoogleKeychain.loadClient() else { throw GoogleRSVPError.notConnected }
        let request = GoogleAuth.tokenExchangeRequest(code: code, verifier: verifier, client: client, redirectURI: redirectURI)
        let token = try await tokenCall(request, previous: nil)
        guard GoogleKeychain.saveToken(token) else { throw GoogleSessionError.keychain }
        return token
    }

    func accessToken(email: String, forceRefresh: Bool) async throws -> String {
        guard let token = GoogleKeychain.loadToken(email) else { throw GoogleRSVPError.notConnected }
        if !forceRefresh, !token.needsRefresh() { return token.accessToken }
        guard let client = GoogleKeychain.loadClient() else { throw GoogleRSVPError.notConnected }
        if let running = refreshing[email] { return try await running.value.accessToken }
        let task = Task { () throws -> GoogleToken in
            let request = GoogleAuth.refreshRequest(refreshToken: token.refreshToken, client: client)
            let fresh = try await self.tokenCall(request, previous: token)
            guard GoogleKeychain.saveToken(fresh) else { throw GoogleSessionError.keychain }
            return fresh
        }
        refreshing[email] = task
        defer { refreshing[email] = nil }
        do {
            return try await task.value.accessToken
        } catch GoogleAuthError.rejected {
            throw GoogleRSVPError.unauthorized
        }
    }

    /// Deletes the local token first, then revokes at Google (best effort, short timeout).
    func signOut(email: String) async {
        refreshing[email]?.cancel()
        refreshing[email] = nil
        await GoogleSignOut.run(
            refreshToken: GoogleKeychain.loadToken(email)?.refreshToken,
            deleteLocal: { GoogleKeychain.deleteToken(email) },
            transport: transport)
    }

    private func tokenCall(_ request: URLRequest, previous: GoogleToken?) async throws -> GoogleToken {
        let reply: (data: Data, status: Int)
        do {
            reply = try await transport.send(request)
        } catch {
            throw GoogleRSVPError.network
        }
        return try GoogleAuth.token(from: reply.data, now: Date(), previous: previous)
    }
}

enum GoogleSessionError: Error {
    case keychain
}
