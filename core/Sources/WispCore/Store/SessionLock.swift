import Foundation

public struct SessionLock: Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/wisp/locks", isDirectory: true)

    private let directory: URL
    private let poll: Duration

    public init(directory: URL = SessionLock.defaultDirectory, poll: Duration = .milliseconds(200)) {
        self.directory = directory
        self.poll = poll
    }

    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        public func release() {
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }

        deinit { release() }
    }

    public enum LockError: Error, LocalizedError {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): "não consegui travar a sessão: \(reason)"
            }
        }
    }

    public func tryAcquire(sessionId: String) throws -> Lease? {
        let path = try path(for: sessionId)
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LockError.unavailable(String(cString: strerror(errno))) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Lease(descriptor: descriptor) }
        let reason = errno
        close(descriptor)
        if reason == EWOULDBLOCK { return nil }
        throw LockError.unavailable(String(cString: strerror(reason)))
    }

    public func acquire(sessionId: String, onBusy: @Sendable () -> Void = {}) async throws -> Lease {
        var announced = false
        while true {
            try Task.checkCancellation()
            if let lease = try tryAcquire(sessionId: sessionId) { return lease }
            if !announced {
                announced = true
                onBusy()
            }
            try await Task.sleep(for: poll)
        }
    }

    private func path(for sessionId: String) throws -> String {
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != ".", sessionId != ".." else {
            throw LockError.unavailable("session id inválido")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("\(sessionId).lock").path
    }
}
