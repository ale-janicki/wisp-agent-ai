import Foundation

/// The app's half of the file-based approval channel the Python core writes (`wisp.approvals`): a tool
/// drops `<id>.json` and waits; the app (or the Telegram bot) answers with an exclusive `<id>.decision`.
public final class ToolApprovals: @unchecked Sendable {
    public static let idPrefix = "tool:"
    /// The tool gives up after 600 s; an older file is an orphan (its tool died) and is never shown.
    public static let maxAge: Double = 600

    /// `$XDG_STATE_HOME/wisp/approvals`, else `~/.local/state/wisp/approvals`: the same place `WispPaths.for_os` picks on macOS.
    public static var defaultDirectory: URL {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".local/state", isDirectory: true)
        return state.appendingPathComponent("wisp/approvals", isDirectory: true)
    }

    private struct RequestFile: Decodable {
        let id: String
        let tool: String
        let summary: String
        let detail: String
        let created: Double
    }

    private let directory: URL
    private let now: @Sendable () -> Double
    private let queue = DispatchQueue(label: "wisp.tool-approvals")
    private var source: DispatchSourceFileSystemObject?

    /// `now` is wall-clock epoch seconds, the same clock `created` is written with.
    public init(directory: URL = ToolApprovals.defaultDirectory, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = directory
        self.now = now
    }

    public var isWatching: Bool { source != nil }

    deinit { source?.cancel() }

    /// Waiting requests, oldest first. Unreadable, corrupt, oddly named or stale (older than `maxAge`) files are skipped.
    public func pending() -> [PermissionRequest] {
        guard isSafeDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [(created: Double, request: PermissionRequest)] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(".json".count))
            guard Self.isValid(id),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).decision").path),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let file = try? JSONDecoder().decode(RequestFile.self, from: data),
                  file.id == id, now() - file.created <= Self.maxAge else { continue }
            found.append((file.created, PermissionRequest(
                id: Self.idPrefix + id, toolName: file.tool, summary: file.summary, detail: file.detail,
                requiresExpansion: true
            )))
        }
        return found.sorted { $0.created < $1.created }.map(\.request)
    }

    /// False when the id is not a tool approval, the request is gone, or someone already answered.
    public func decide(id: String, allow: Bool) -> Bool {
        guard id.hasPrefix(Self.idPrefix) else { return false }
        let raw = String(id.dropFirst(Self.idPrefix.count))
        guard Self.isValid(raw), isSafeDirectory(),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(raw).json").path) else { return false }
        let target = directory.appendingPathComponent("\(raw).decision").path
        let fd = open(target, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { return false }
        let bytes = Array((allow ? "allow" : "deny").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        close(fd)
        if written != bytes.count || !stillOpen(raw) {
            unlink(target)
            return false
        }
        return true
    }

    private struct Tombstone: Decodable { let outcome: String }

    /// False once the tool gave up on the request (its tombstone says expired or cancelled) or took it away without
    /// leaving one: an answer written now would be shown as "permitido" for something that did not happen.
    private func stillOpen(_ raw: String) -> Bool {
        let done = directory.appendingPathComponent("\(raw).done")
        guard let data = try? Data(contentsOf: done), let tombstone = try? JSONDecoder().decode(Tombstone.self, from: data) else {
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(raw).json").path)
        }
        return tombstone.outcome != "expired" && tombstone.outcome != "cancelled"
    }

    /// Calls `onChange` (on a background queue) whenever the directory changes. Creates it with 0700 when
    /// missing; refuses a symlink. Returns false when nothing is being watched.
    @discardableResult
    public func watch(onChange: @escaping @Sendable () -> Void) -> Bool {
        guard source == nil, ensureDirectory() else { return false }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        watcher.setEventHandler(handler: onChange)
        watcher.setCancelHandler { close(fd) }
        source = watcher
        watcher.resume()
        return true
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func ensureDirectory() -> Bool {
        if isSymlink() { return false }
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { return false }
        }
        let mode = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.posixPermissions] as? Int
        if mode.map({ $0 & 0o777 != 0o700 }) == true {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return isSafeDirectory()
    }

    private func isSymlink() -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func isSafeDirectory() -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isValid(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
