import Foundation

/// The assistant's personality text. The CLI is the one renderer (`wisp soul render`); this runs it and remembers the answer
/// until `profile.json`, `wisp.json` or `agente.md` change on disk, so starting a session costs one process only after an edit.
public enum SoulRenderer {
    public static let timeout: TimeInterval = 5
    /// A failed render is remembered this long, so a broken CLI costs one timeout a minute, not one per session.
    public static let failureTTL: TimeInterval = 60

    public static func arguments(engine: String) -> [String] {
        ["soul", "render", "--engine", engine, "--json"]
    }

    private struct Report: Decodable {
        let source: String
        let text: String
    }

    /// The text to inject; empty when the user's own assistant supplies the personality (or on any failure: the engine
    /// then runs as it did before the soul existed).
    public static func decode(_ output: Data) -> String? {
        (try? JSONDecoder().decode(Report.self, from: output))?.text
    }

    public final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (stamp: String, text: String)] = [:]
        private var failures: [String: (stamp: String, at: Date)] = [:]

        public init() {}

        func value(key: String, stamp: String) -> String? {
            lock.withLock { entries[key].flatMap { $0.stamp == stamp ? $0.text : nil } }
        }

        func failedRecently(key: String, stamp: String, now: Date) -> Bool {
            lock.withLock { failures[key].map { $0.stamp == stamp && now.timeIntervalSince($0.at) < SoulRenderer.failureTTL } ?? false }
        }

        func store(_ text: String, key: String, stamp: String) {
            lock.withLock {
                entries[key] = (stamp, text)
                failures[key] = nil
            }
        }

        func storeFailure(key: String, stamp: String, now: Date) {
            lock.withLock { failures[key] = (stamp, now) }
        }
    }

    public static let shared = Cache()

    /// Whether `~/.claude` (or a file or folder Wisp would install there) is a symlink: the CLI then defaults the source to the
    /// user's own assistant, so the text depends on it.
    public static func managedElsewhere(home: URL) -> Bool {
        let claude = home.appendingPathComponent(".claude")
        let guarded = [claude, claude.appendingPathComponent("CLAUDE.md"), claude.appendingPathComponent("settings.json")]
            + ["agents", "skills", "commands"].map { claude.appendingPathComponent($0) }
        return guarded.contains { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil }
    }

    /// Modification times of every file the text depends on, plus `state`; a missing file counts as its own state.
    public static func stamp(of files: [URL], state: String = "") -> String {
        files.map { url in
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            return "\(url.path)=\(date.map { String($0.timeIntervalSince1970) } ?? "-")"
        }.joined(separator: "|") + "|" + state
    }

    public static func text(
        wisp: URL, environment: [String: String], engine: String, watching files: [URL], state: String = "",
        timeout: TimeInterval = SoulRenderer.timeout, now: Date = Date(), cache: Cache = shared
    ) -> String {
        let key = "\(wisp.path)#\(engine)"
        let stamp = stamp(of: files, state: state)
        if let cached = cache.value(key: key, stamp: stamp) { return cached }
        if cache.failedRecently(key: key, stamp: stamp, now: now) { return "" }
        guard case .success(let output) = CommandRunner.run(
            executable: wisp, arguments: arguments(engine: engine), environment: environment, timeout: timeout),
            !output.timedOut, output.status == 0, let text = decode(output.stdout)
        else {
            cache.storeFailure(key: key, stamp: stamp, now: now)
            return ""
        }
        cache.store(text, key: key, stamp: stamp)
        return text
    }

    /// Appends the soul to an engine's instructions, separated by a blank line; nothing to append leaves them untouched.
    public static func appending(_ soul: String, to instructions: String) -> String {
        soul.isEmpty ? instructions : instructions + "\n\n" + soul
    }
}
