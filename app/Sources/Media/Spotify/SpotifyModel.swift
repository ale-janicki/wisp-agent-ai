import AppKit
import Observation
import os
import WispCore

@MainActor @Observable
final class SpotifyModel {
    static let shared = SpotifyModel()

    enum Auth: Equatable { case unknown, signedOut, signingIn, signedIn }

    enum Load<Value: Equatable>: Equatable {
        case idle, loading
        case loaded(Value)
        case failed(String)
    }

    private(set) var auth: Auth = .unknown
    private(set) var authError: String?
    private(set) var playlists: Load<[SpotifyPlaylist]> = .idle
    private(set) var results: Load<SpotifySearchResults> = .idle
    private(set) var openPlaylist: SpotifyPlaylist?
    private(set) var playlistTracks: Load<[SpotifyTrack]> = .idle
    private(set) var notice: Notice?
    private(set) var busyURI: String?

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    @ObservationIgnored private let api = SpotifyAPI.shared
    @ObservationIgnored private var loopback: SpotifyLoopback?
    @ObservationIgnored private var playlistsLoadedAt: Date?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var tracksGeneration = 0
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.owner.wisp", category: "spotify")

    static let searchDebounce: Duration = .milliseconds(300)
    private static let loginTimeout: Duration = .seconds(300)
    private static let playlistCap = 500
    private static let trackCap = 500
    private static let playlistsMaxAge: TimeInterval = 300
    private static let searchLimit = 8

    var clientID: String { AppSettings.shared.settings.spotifyClientID }
    var hasClientID: Bool { !clientID.isEmpty }

    // MARK: Session

    func bootstrap() {
        guard auth == .unknown else {
            if auth == .signedIn { loadPlaylistsIfStale() }
            return
        }
        Task {
            let signedIn = await api.isSignedIn()
            guard auth == .unknown else { return }
            auth = signedIn ? .signedIn : .signedOut
            if signedIn { loadPlaylistsIfStale() }
        }
    }

    func connect() {
        guard hasClientID, auth != .signingIn else { return }
        let clientID = clientID
        auth = .signingIn
        authError = nil
        sessionGeneration += 1
        let session = sessionGeneration
        Task {
            do {
                let verifier = SpotifyPKCE.makeVerifier()
                let state = SpotifyPKCE.makeState()
                let loopback = try SpotifyLoopback(port: SpotifyAuth.redirectPort, path: SpotifyAuth.redirectPath, state: state)
                self.loopback = loopback
                try await loopback.start()
                guard session == sessionGeneration else {
                    loopback.cancel()
                    return
                }
                let url = SpotifyAuth.authorizationURL(
                    clientID: clientID,
                    redirectURI: SpotifyAuth.redirectURI,
                    state: state,
                    challenge: SpotifyPKCE.challenge(for: verifier),
                    scopes: SpotifyAuth.scopes
                )
                NSWorkspace.shared.open(url)
                let callback = try await loopback.result(timeout: Self.loginTimeout)
                guard session == sessionGeneration else { return }
                self.loopback = nil
                switch callback {
                case .denied:
                    auth = .signedOut
                    authError = "O Spotify não autorizou o Wisp; clique em Conectar Spotify para tentar de novo."
                case .code(let code):
                    try await api.signIn(code: code, verifier: verifier, clientID: clientID)
                    guard session == sessionGeneration else {
                        await api.signOut()
                        return
                    }
                    auth = .signedIn
                    loadPlaylists()
                }
            } catch {
                guard session == sessionGeneration else { return }
                self.loopback = nil
                auth = .signedOut
                authError = Self.loginMessage(error)
                if let authError { log.error("spotify login failed: \(authError, privacy: .public)") }
            }
        }
    }

    func cancelConnect() {
        loopback?.cancel()
    }

    func signOut() {
        sessionGeneration += 1
        loopback?.cancel()
        loopback = nil
        auth = .signedOut
        authError = nil
        playlists = .idle
        results = .idle
        openPlaylist = nil
        playlistTracks = .idle
        playlistsLoadedAt = nil
        setNotice(nil)
        Task { await api.signOut() }
    }

    // MARK: Library

    func loadPlaylistsIfStale() {
        if case .loading = playlists { return }
        if case .loaded = playlists, let at = playlistsLoadedAt, Date().timeIntervalSince(at) < Self.playlistsMaxAge { return }
        loadPlaylists()
    }

    func loadPlaylists() {
        if case .loaded = playlists {} else { playlists = .loading }
        let clientID = clientID
        Task {
            do {
                var all: [SpotifyPlaylist] = []
                var offset = 0
                while all.count < Self.playlistCap {
                    let page = try await api.get(SpotifyPage<SpotifyPlaylist>.self, .myPlaylists(limit: SpotifyEndpoint.pageLimitMax, offset: offset), clientID: clientID)
                    all += page.items
                    offset += page.limit
                    if !page.hasMore || page.limit == 0 { break }
                }
                playlists = .loaded(all)
                playlistsLoadedAt = Date()
            } catch {
                playlists = .failed(handle(error, action: "carregar suas playlists"))
            }
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        guard !trimmed.isEmpty else {
            results = .idle
            return
        }
        try? await Task.sleep(for: Self.searchDebounce)
        guard !Task.isCancelled, generation == searchGeneration else { return }
        if case .loaded = results {} else { results = .loading }
        do {
            let found = try await api.get(SpotifySearchResults.self, .search(query: trimmed, limit: Self.searchLimit), clientID: clientID)
            guard generation == searchGeneration else { return }
            results = .loaded(found)
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = .failed(handle(error, action: "buscar no Spotify"))
        }
    }

    func open(_ playlist: SpotifyPlaylist) {
        openPlaylist = playlist
        playlistTracks = .loading
        tracksGeneration += 1
        let generation = tracksGeneration
        let clientID = clientID
        Task {
            do {
                var all: [SpotifyTrack] = []
                var offset = 0
                while all.count < Self.trackCap {
                    let page = try await api.get(SpotifyPage<SpotifyPlaylistEntry>.self, .playlistItems(id: playlist.id, limit: SpotifyEndpoint.pageLimitMax, offset: offset), clientID: clientID)
                    all += page.items.compactMap(\.track)
                    offset += page.limit
                    if !page.hasMore || page.limit == 0 { break }
                }
                guard generation == tracksGeneration else { return }
                playlistTracks = .loaded(all)
            } catch SpotifyAPI.Failure.api(.forbidden) {
                guard generation == tracksGeneration else { return }
                playlistTracks = .failed("O Spotify só lista as músicas das playlists que você criou ou edita; use Tocar para ouvir esta.")
            } catch {
                guard generation == tracksGeneration else { return }
                playlistTracks = .failed(handle(error, action: "abrir esta playlist"))
            }
        }
    }

    func closePlaylist() {
        tracksGeneration += 1
        openPlaylist = nil
        playlistTracks = .idle
    }

    // MARK: Player

    func play(_ play: SpotifyPlay, key: String, media: NowPlayingService?) {
        perform(key: key, action: "tocar", media: media) { api, clientID, device in
            try await api.send(.play(play, deviceID: device), clientID: clientID)
        }
    }

    func enqueue(_ track: SpotifyTrack) {
        perform(key: track.uri, action: "adicionar à fila", media: nil, success: "“\(track.name)” entra a seguir na fila.") { api, clientID, device in
            try await api.send(.queue(uri: track.uri, deviceID: device), clientID: clientID)
        }
    }

    private func perform(
        key: String,
        action: String,
        media: NowPlayingService?,
        success: String? = nil,
        _ command: @escaping @Sendable (SpotifyAPI, String, String?) async throws -> Void
    ) {
        guard busyURI == nil else { return }
        busyURI = key
        setNotice(nil)
        let clientID = clientID
        let api = api
        Task {
            defer { busyURI = nil }
            do {
                do {
                    try await command(api, clientID, nil)
                } catch SpotifyAPI.Failure.api(.noActiveDevice) {
                    guard let device = SpotifyDevice.pick(try await api.devices(clientID: clientID)), let id = device.id else {
                        throw SpotifyAPI.Failure.api(.noActiveDevice)
                    }
                    try await command(api, clientID, id)
                }
                if let success { setNotice(Notice(text: success, isError: false), clearAfter: .seconds(4)) }
                if let media {
                    try? await Task.sleep(for: .milliseconds(700))
                    media.refresh()
                }
            } catch {
                setNotice(Notice(text: handle(error, action: action), isError: true), clearAfter: .seconds(8))
            }
        }
    }

    // MARK: Messages (rule 23: one plain sentence naming the action)

    private func handle(_ error: Error, action: String) -> String {
        if let failure = error as? SpotifyAPI.Failure {
            switch failure {
            case .notSignedIn, .sessionExpired:
                signOutLocally()
                return "Sua sessão do Spotify expirou; clique em Conectar Spotify."
            case .api(.unauthorized):
                return "O Spotify recusou o acesso para \(action); saia e conecte de novo."
            case .api(.premiumRequired):
                return "Para \(action) pelo Wisp a conta precisa de Spotify Premium."
            case .api(.noActiveDevice):
                return "Abra o Spotify em algum dispositivo para \(action)."
            case .api(.forbidden):
                return "O Spotify negou \(action); confira se sua conta está em Users Management do app."
            case .api(.notFound):
                return "O Spotify não encontrou o item para \(action)."
            case .api(.rateLimited(let seconds, let quota)):
                return quota
                    ? "A cota do app no Spotify acabou por agora; tente \(action) mais tarde."
                    : "O Spotify pediu uma pausa; tente \(action) em \(Int(seconds.rounded(.up))) s."
            case .api(.server(let status, _)):
                return "O Spotify respondeu erro \(status) ao \(action); tente de novo."
            case .network:
                return "Sem conexão com o Spotify para \(action); confira a internet."
            case .rejected(let reason):
                return "O Spotify recusou o pedido para \(action): \(reason)."
            case .decoding:
                return "Não entendi a resposta do Spotify ao \(action)."
            case .keychain:
                return "Não consegui guardar a sessão do Spotify no Keychain."
            }
        }
        return "Não consegui \(action) no Spotify."
    }

    private func signOutLocally() {
        guard auth == .signedIn else { return }
        auth = .signedOut
        playlists = .idle
        results = .idle
        openPlaylist = nil
        playlistTracks = .idle
    }

    private static func loginMessage(_ error: Error) -> String? {
        switch error {
        case SpotifyLoopback.Failure.cancelled:
            return nil
        case SpotifyLoopback.Failure.portBusy(let port):
            return "A porta \(port) está ocupada; feche o que a usa e clique em Conectar Spotify de novo."
        case SpotifyLoopback.Failure.timedOut:
            return "O login do Spotify expirou; clique em Conectar Spotify de novo."
        case SpotifyLoopback.Failure.callback:
            return "A resposta do Spotify não conferiu; clique em Conectar Spotify de novo."
        case SpotifyAPI.Failure.rejected(let reason):
            return "O Spotify recusou o login (\(reason)); confira o Client ID e o Redirect URI do app."
        case SpotifyAPI.Failure.network:
            return "Sem conexão com o Spotify; confira a internet e conecte de novo."
        case SpotifyAPI.Failure.keychain:
            return "Não consegui guardar a sessão do Spotify no Keychain."
        default:
            return "Não consegui conectar ao Spotify; clique em Conectar Spotify de novo."
        }
    }

    private func setNotice(_ notice: Notice?, clearAfter delay: Duration? = nil) {
        noticeTask?.cancel()
        self.notice = notice
        guard let delay, notice != nil else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    #if DEBUG
    func applyForSnapshot(auth: Auth) {
        self.auth = auth
    }
    #endif
}
