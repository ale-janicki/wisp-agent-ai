import Foundation
import Network
import WispCore

final class SpotifyLoopback: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case portBusy(UInt16)
        case timedOut
        case cancelled
        case callback(SpotifyCallbackError)
        case listener(String)
    }

    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).spotify.loopback", qos: .userInitiated)
    private let listener: NWListener
    private let port: UInt16
    private let path: String
    private let state: String
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<SpotifyCallback, Error>?
    private var outcome: Result<SpotifyCallback, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private static let headLimit = 16 * 1024

    init(port: UInt16, path: String, state: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.listener("porta inválida") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.port = port
        self.path = path
        self.state = state
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.ready = continuation
                self.listener.stateUpdateHandler = { state in self.listenerChanged(state) }
                self.listener.newConnectionHandler = { connection in self.accept(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func result(timeout: Duration) async throws -> SpotifyCallback {
        let seconds = Double(timeout.components.seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpotifyCallback, Error>) in
                queue.async {
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome)
                        return
                    }
                    self.waiter = continuation
                    self.queue.asyncAfter(deadline: .now() + seconds) { self.finish(.failure(Failure.timedOut)) }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(Failure.cancelled)) }
    }

    // MARK: Queue-confined

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
        case .failed(let error), .waiting(let error):
            let failure: Failure = if case .posix(.EADDRINUSE) = error { .portBusy(port) } else { .listener(error.localizedDescription) }
            if let ready {
                ready.resume(throwing: failure)
                self.ready = nil
            }
            finish(.failure(failure))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let head = String(decoding: buffer, as: UTF8.self)
            if head.contains("\r\n\r\n") || complete || error != nil || buffer.count > Self.headLimit {
                self.handle(head: head, on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        guard let target = SpotifyCallback.requestTarget(fromHead: head) else {
            respond(connection, status: "400 Bad Request", message: nil)
            return
        }
        do {
            let callback = try SpotifyCallback.parse(target: target, path: path, state: state)
            switch callback {
            case .code: respond(connection, status: "200 OK", message: "Spotify conectado. Pode fechar esta aba e voltar ao Wisp.")
            case .denied: respond(connection, status: "200 OK", message: "O Wisp não foi autorizado. Pode fechar esta aba.")
            }
            finish(.success(callback))
        } catch SpotifyCallbackError.notCallback {
            respond(connection, status: "404 Not Found", message: nil)
        } catch {
            let failure = (error as? SpotifyCallbackError) ?? .missingCode
            respond(connection, status: "400 Bad Request", message: "A resposta do Spotify não confere. Volte ao Wisp e conecte de novo.")
            finish(.failure(Failure.callback(failure)))
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String?) {
        let body = message.map(Self.page) ?? ""
        let bytes = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<SpotifyCallback, Error>) {
        guard outcome == nil else { return }
        outcome = result
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        if let ready, case .failure(let error) = result {
            ready.resume(throwing: error)
            self.ready = nil
        }
        if let waiter {
            waiter.resume(with: result)
            self.waiter = nil
        }
    }

    private static func page(_ message: String) -> String {
        """
        <!doctype html><html lang="pt-BR"><meta charset="utf-8"><title>Wisp</title>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#111214;color:#F2F2F3;font:15px -apple-system,system-ui,sans-serif">
        <p>\(message)</p></body></html>
        """
    }
}
