import Foundation
import WispCore

actor SpotifyAPI {
    static let shared = SpotifyAPI()

    enum Failure: Error, Equatable {
        case notSignedIn
        case sessionExpired
        case rejected(String)
        case api(SpotifyFailure)
        case network(String)
        case decoding
        case keychain
    }

    private var token: SpotifyToken?
    private var loaded = false
    private var refreshing: Task<SpotifyToken, Error>?
    private let session = URLSession(configuration: .ephemeral)

    private static let maxRateLimitRetries = 2
    private static let maxRetryAfter: TimeInterval = 10

    func isSignedIn() -> Bool {
        loadIfNeeded()
        return token != nil
    }

    func signIn(code: String, verifier: String, clientID: String) async throws {
        let request = SpotifyAuth.tokenExchangeRequest(code: code, verifier: verifier, clientID: clientID, redirectURI: SpotifyAuth.redirectURI)
        let token = try await tokenCall(request, previous: nil)
        try store(token)
    }

    func signOut() {
        refreshing?.cancel()
        refreshing = nil
        token = nil
        loaded = true
        SpotifyKeychain.delete()
    }

    func get<Value: Decodable & Sendable>(_ type: Value.Type, _ endpoint: SpotifyEndpoint, clientID: String) async throws -> Value {
        let data = try await send(endpoint, clientID: clientID)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw Failure.decoding
        }
    }

    func devices(clientID: String) async throws -> [SpotifyDevice] {
        let data = try await send(.devices, clientID: clientID)
        do {
            return try SpotifyDevice.parseList(data)
        } catch {
            throw Failure.decoding
        }
    }

    @discardableResult
    func send(_ endpoint: SpotifyEndpoint, clientID: String) async throws -> Data {
        var refreshed = false
        var rateLimited = 0
        while true {
            let access = try await accessToken(clientID: clientID, forceRefresh: false)
            let (data, response) = try await perform(endpoint.urlRequest(accessToken: access))
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            guard let failure = SpotifyFailure.classify(status: response.statusCode, body: data, retryAfter: retryAfter, player: endpoint.isPlayer) else {
                return data
            }
            switch failure {
            case .unauthorized where !refreshed:
                refreshed = true
                _ = try await accessToken(clientID: clientID, forceRefresh: true)
            case .rateLimited(let seconds, let quota) where !quota && rateLimited < Self.maxRateLimitRetries && seconds <= Self.maxRetryAfter:
                rateLimited += 1
                try await Task.sleep(for: .seconds(seconds))
            default:
                throw Failure.api(failure)
            }
        }
    }

    // MARK: Session

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        token = SpotifyKeychain.load()
    }

    private func store(_ token: SpotifyToken) throws {
        do {
            try SpotifyKeychain.save(token)
        } catch {
            throw Failure.keychain
        }
        self.token = token
        loaded = true
    }

    private func accessToken(clientID: String, forceRefresh: Bool) async throws -> String {
        loadIfNeeded()
        guard let current = token else { throw Failure.notSignedIn }
        guard forceRefresh || current.needsRefresh() else { return current.accessToken }
        return try await refresh(from: current, clientID: clientID).accessToken
    }

    private func refresh(from current: SpotifyToken, clientID: String) async throws -> SpotifyToken {
        if let refreshing {
            do {
                return try await refreshing.value
            } catch Failure.rejected {
                throw Failure.sessionExpired
            }
        }
        let request = SpotifyAuth.refreshRequest(refreshToken: current.refreshToken, clientID: clientID)
        let task = Task { try await self.tokenCall(request, previous: current) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let next = try await task.value
            try store(next)
            return next
        } catch Failure.rejected {
            signOut()
            throw Failure.sessionExpired
        }
    }

    private func tokenCall(_ request: URLRequest, previous: SpotifyToken?) async throws -> SpotifyToken {
        let (data, _) = try await perform(request)
        do {
            return try SpotifyAuth.token(from: data, now: Date(), previous: previous)
        } catch SpotifyAuthError.rejected(let code, let description) {
            throw Failure.rejected(description.isEmpty ? code : description)
        } catch {
            throw Failure.decoding
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.network("resposta inválida") }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }
}
