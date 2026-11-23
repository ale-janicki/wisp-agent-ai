import AppKit
import Observation
import os
import WispCore

@MainActor @Observable
final class GoogleModel {
    static let shared = GoogleModel()

    enum Phase: Equatable { case idle, signingIn }

    private(set) var client: GoogleClient?
    private(set) var accounts: [String] = []
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    private var pending: [String: Pending] = [:]

    private struct Pending {
        var choice: GoogleRSVPChoice
        var since: Date
    }

    @ObservationIgnored private var loopback: SpotifyLoopback?
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "google")

    private static let loginTimeout: Duration = .seconds(300)
    private static let pendingLifetime: TimeInterval = 600
    private static let syncChecks: [Duration] = [.seconds(3), .seconds(8), .seconds(20), .seconds(45)]
    private static let portAttempts = 5

    var hasClient: Bool { client != nil }
    var isConnected: Bool { !accounts.isEmpty }

    init() {
        reload()
    }

    func reload() {
        client = GoogleKeychain.loadClient()
        accounts = GoogleKeychain.emails()
    }

    // MARK: Client JSON

    func importClient(from url: URL) {
        error = nil
        guard let data = try? Data(contentsOf: url) else {
            error = "Não consegui ler o arquivo."
            return
        }
        do {
            let parsed = try GoogleClient.parse(data)
            guard GoogleKeychain.saveClient(parsed) else {
                error = "Não consegui guardar o cliente do Google no Keychain."
                return
            }
            reload()
        } catch GoogleClient.ParseError.webClient {
            error = "Este JSON é de um cliente \"Aplicativo da Web\". Crie um cliente do tipo \"App para computador\"."
        } catch GoogleClient.ParseError.notJSON {
            error = "O arquivo não é um JSON. Use o credentials.json baixado do Google Cloud."
        } catch {
            self.error = "O JSON não tem client_id e client_secret de um app para computador."
        }
    }

    func removeClient() {
        let emails = accounts
        Task {
            for email in emails { await GoogleSession.shared.signOut(email: email) }
            GoogleKeychain.deleteClient()
            reload()
        }
    }

    // MARK: Sign in

    func connect() {
        guard let client, phase != .signingIn else { return }
        phase = .signingIn
        error = nil
        sessionGeneration += 1
        let session = sessionGeneration
        Task {
            do {
                let verifier = SpotifyPKCE.makeVerifier()
                let state = SpotifyPKCE.makeState()
                let (loopback, port) = try await Self.openLoopback(state: state)
                self.loopback = loopback
                guard session == sessionGeneration else {
                    loopback.cancel()
                    return
                }
                let redirect = GoogleAuth.redirectURI(port: port)
                let url = GoogleAuth.authorizationURL(
                    clientID: client.clientID, redirectURI: redirect, state: state, challenge: SpotifyPKCE.challenge(for: verifier))
                NSWorkspace.shared.open(url)
                let callback = try await loopback.result(timeout: Self.loginTimeout)
                guard session == sessionGeneration else { return }
                self.loopback = nil
                switch callback {
                case .denied:
                    error = "O Google não autorizou o Wisp; clique em Conectar de novo."
                case .code(let code):
                    let token = try await GoogleSession.shared.signIn(code: code, verifier: verifier, redirectURI: redirect)
                    guard session == sessionGeneration else {
                        await GoogleSession.shared.signOut(email: token.email)
                        return
                    }
                    reload()
                }
                phase = .idle
            } catch {
                guard session == sessionGeneration else { return }
                self.loopback = nil
                phase = .idle
                self.error = Self.loginMessage(error)
                if let message = self.error { log.error("google login failed: \(message, privacy: .public)") }
            }
        }
    }

    func cancelConnect() {
        sessionGeneration += 1
        loopback?.cancel()
        loopback = nil
        phase = .idle
    }

    func disconnect(_ email: String) {
        Task {
            await GoogleSession.shared.signOut(email: email)
            reload()
        }
    }

    private static func openLoopback(state: String) async throws -> (SpotifyLoopback, UInt16) {
        var lastError: Error = SpotifyLoopback.Failure.listener("sem porta livre")
        for _ in 0..<portAttempts {
            let port = GoogleAuth.randomPort()
            do {
                let loopback = try SpotifyLoopback(port: port, path: GoogleAuth.redirectPath, state: state, brand: "Google")
                try await loopback.start()
                return (loopback, port)
            } catch SpotifyLoopback.Failure.portBusy {
                lastError = SpotifyLoopback.Failure.portBusy(port)
            }
        }
        throw lastError
    }

    private static func loginMessage(_ error: Error) -> String? {
        switch error {
        case SpotifyLoopback.Failure.cancelled: nil
        case SpotifyLoopback.Failure.portBusy, SpotifyLoopback.Failure.listener: "Não consegui abrir a porta local para o login; clique em Conectar de novo."
        case SpotifyLoopback.Failure.timedOut: "O login do Google expirou; clique em Conectar de novo."
        case SpotifyLoopback.Failure.callback: "A resposta do Google não conferiu; clique em Conectar de novo."
        case GoogleAuthError.rejected(let code, _): "O Google recusou o login (\(code)); confira o cliente OAuth e se sua conta está como usuário de teste."
        case GoogleAuthError.missingRefreshToken: "O Google não devolveu o acesso permanente; remova o Wisp em myaccount.google.com/permissions e conecte de novo."
        case GoogleAuthError.missingEmail: "O Google não informou o e-mail da conta; conecte de novo."
        case GoogleRSVPError.network: "Sem conexão com o Google; confira a internet e conecte de novo."
        case GoogleSessionError.keychain: "Não consegui guardar a sessão do Google no Keychain."
        default: "Não consegui conectar ao Google; clique em Conectar de novo."
        }
    }

    // MARK: RSVP

    /// The account to answer with, when this invitation can be answered at all.
    func account(for event: CalEvent) -> String? {
        GoogleCalendarAPI.account(for: event.attendees, connected: accounts)
    }

    /// The answer shown for an event: the one just sent while EventKit has not caught up, else nil.
    func syncing(_ event: CalEvent) -> GoogleRSVPChoice? {
        guard let item = pending[event.uid] else { return nil }
        if Date().timeIntervalSince(item.since) > Self.pendingLifetime { return nil }
        return item.choice
    }

    /// Drops the optimistic answer once EventKit shows it (or after it has been stale for too long).
    func reconcile(_ event: CalEvent) {
        guard let item = pending[event.uid] else { return }
        let mine = event.attendees.first(where: \.isMe)?.status
        if mine == item.choice.attendeeStatus || Date().timeIntervalSince(item.since) > Self.pendingLifetime {
            pending[event.uid] = nil
        }
    }

    /// Sends the answer to Google. Returns the error text, or nil on success.
    func respond(to event: CalEvent, choice: GoogleRSVPChoice, calendar: Calendar, onSync: @escaping @MainActor () -> Void) async -> String? {
        guard let email = account(for: event) else { return GoogleRSVPError.notInvitee.message }
        guard let uid = event.iCalUID else { return "O macOS não informou o identificador deste evento." }
        let service = GoogleRSVPService(transport: URLSessionGoogleTransport()) { force in
            try await GoogleSession.shared.accessToken(email: email, forceRefresh: force)
        }
        do {
            try await service.respond(
                iCalUID: uid, start: event.start, allDay: event.allDay, isRecurring: event.isRecurring, calendar: calendar,
                choice: choice, accountEmail: email)
        } catch let failure as GoogleRSVPError {
            return failure.message
        } catch GoogleAuthError.rejected {
            return GoogleRSVPError.unauthorized.message
        } catch {
            return "Não consegui responder pelo Google."
        }
        pending[event.uid] = Pending(choice: choice, since: Date())
        Task { [weak self] in
            for delay in Self.syncChecks {
                try? await Task.sleep(for: delay)
                guard self?.pending[event.uid] != nil else { return }
                onSync()
            }
        }
        return nil
    }
}
