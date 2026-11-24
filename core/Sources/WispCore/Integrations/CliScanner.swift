import Foundation

/// A command-line tool the AI may run from its shell. Add a tool by adding a line to `CliCatalog.tools`.
public struct CliTool: Sendable, Equatable {
    public var name: String
    public var versionArguments: [String]
    /// nil: no auth is shown for this tool.
    public var auth: CliAuth?

    public init(_ name: String, version: [String] = ["--version"], auth: CliAuth? = nil) {
        self.name = name
        self.versionArguments = version
        self.auth = auth
    }
}

/// A local, read-only, offline way to tell that a tool is set up. `label` is the only thing ever shown.
public enum CliAuth: Sendable, Equatable {
    /// Exit 0, and non-blank stdout when `needsOutput`, means set up. The output itself is dropped.
    case command([String], needsOutput: Bool, label: String)
    /// `relativePath` (from home) exists and has one of `keys` as a YAML key under a host. Values are never read into the result.
    case hostsFile(relativePath: String, keys: [String], label: String)
}

public enum CliCatalog {
    public static let tools: [CliTool] = [
        CliTool("gh", auth: .hostsFile(relativePath: ".config/gh/hosts.yml", keys: ["oauth_token", "user"], label: "logado")),
        CliTool("git"),
        CliTool("supabase"),
        CliTool("aws", auth: .command(["configure", "list-profiles"], needsOutput: true, label: "perfil configurado")),
        CliTool("gcloud"),
        CliTool("az"),
        CliTool("vercel"),
        CliTool("netlify"),
        CliTool("flyctl", version: ["version"]),
        CliTool("firebase"),
        CliTool("docker"),
        CliTool("kubectl", version: ["version", "--client"]),
        CliTool("terraform", version: ["version"]),
        CliTool("stripe"),
        CliTool("psql"),
        CliTool("mysql"),
        CliTool("redis-cli"),
        CliTool("node"),
        CliTool("npm"),
        CliTool("pnpm"),
        CliTool("bun"),
        CliTool("python3"),
        CliTool("uv"),
        CliTool("pip"),
        CliTool("go", version: ["version"]),
        CliTool("cargo"),
        CliTool("java", version: ["-version"]),
        CliTool("ffmpeg", version: ["-version"]),
        CliTool("jq"),
        CliTool("rg"),
        CliTool("brew"),
        CliTool("codex"),
        CliTool("claude"),
        CliTool("ollama"),
    ]
}

public struct CliStatus: Sendable, Equatable, Identifiable {
    public var name: String
    /// The directory holding the binary, with the home folder shown as `~`; nil when the tool was not found.
    public var directory: String?
    public var version: String?
    /// A short label ("logado", "perfil configurado") when the tool is set up; nil otherwise.
    public var auth: String?

    public var id: String { name }
    public var isInstalled: Bool { directory != nil }
}

/// Finds the catalog's tools on a PATH and asks each for its version. Probes run on up to `maxParallel` dedicated background threads, each under a timeout. At most
/// `maxParallel` at a time, each under a timeout. A good version line is cached until `clearCache()`; a timeout,
/// a launch failure and anything about auth are never cached.
public final class CliScanner: @unchecked Sendable {
    public static let versionTimeout: TimeInterval = 2
    public static let maxParallel = 4
    static let maxVersionLength = 80
    static let hostsFileLimit = 1_000_000

    private struct Probe { var version: String?; var auth: String? }

    private let lock = NSLock()
    private var versions: [String: String] = [:]

    public init() {}

    public func clearCache() { lock.withLock { versions = [:] } }

    /// Blocks the calling thread until every probe is done: call it from a background queue, not from the cooperative pool.
    public func scan(
        tools: [CliTool] = CliCatalog.tools, path: String, home: String = NSHomeDirectory(),
        timeout: TimeInterval = CliScanner.versionTimeout, fileManager: FileManager = .default
    ) -> [CliStatus] {
        let located = tools.map { ($0, Self.locate($0.name, in: path, fileManager: fileManager)) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let results = ResultBox(count: located.count)
        let work = located.indices.filter { located[$0].1 != nil }
        let next = Counter()
        let done = DispatchGroup()
        for _ in 0..<min(Self.maxParallel, work.count) {
            done.enter()
            let worker = Thread { [self] in
                while let slot = next.take(), slot < work.count {
                    let index = work[slot]
                    guard let found = located[index].1 else { continue }
                    results.set(index, probe(located[index].0, at: found, home: home, environment: environment, timeout: timeout, fileManager: fileManager))
                }
                done.leave()
            }
            worker.qualityOfService = .background
            worker.start()
        }
        done.wait()
        return located.enumerated().map { index, entry in
            let (tool, found) = entry
            guard let found else { return CliStatus(name: tool.name, directory: nil, version: nil, auth: nil) }
            let probe = results.get(index)
            return CliStatus(
                name: tool.name, directory: Self.display(directory: found.deletingLastPathComponent().path, home: home),
                version: probe?.version, auth: probe?.auth)
        }
    }

    public static func locate(_ name: String, in path: String, fileManager: FileManager = .default) -> URL? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The first non-empty line, trimmed and capped; nil when there is none.
    public static func versionLine(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > maxVersionLength ? String(line.prefix(maxVersionLength - 1)) + "…" : line
    }

    public static func display(directory: String, home: String) -> String {
        if directory == home { return "~" }
        return directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
    }

    /// True when `text` has one of `keys` as a YAML key on a line. Only the key is looked at; the value is never kept.
    static func hasYamlKey(_ text: String, keys: [String]) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return keys.contains { trimmed.hasPrefix($0 + ":") }
        }
    }

    private func probe(
        _ tool: CliTool, at url: URL, home: String, environment: [String: String], timeout: TimeInterval, fileManager: FileManager
    ) -> Probe {
        Probe(version: version(tool, at: url, environment: environment, timeout: timeout, fileManager: fileManager),
              auth: auth(tool, at: url, home: home, environment: environment, timeout: timeout, fileManager: fileManager))
    }

    private func version(_ tool: CliTool, at url: URL, environment: [String: String], timeout: TimeInterval, fileManager: FileManager) -> String? {
        let mtime = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let hit = lock.withLock({ versions[key] }) { return hit }
        guard case .success(let output) = CommandRunner.run(
            executable: url, arguments: tool.versionArguments, environment: environment, timeout: timeout),
            !output.timedOut,
            let line = Self.versionLine(String(decoding: output.stdout, as: UTF8.self))
                ?? Self.versionLine(String(decoding: output.stderr, as: UTF8.self)) else { return nil }
        lock.withLock { versions[key] = line }
        return line
    }

    private func auth(
        _ tool: CliTool, at url: URL, home: String, environment: [String: String], timeout: TimeInterval, fileManager: FileManager
    ) -> String? {
        switch tool.auth {
        case nil:
            return nil
        case .command(let arguments, let needsOutput, let label):
            guard case .success(let output) = CommandRunner.run(
                executable: url, arguments: arguments, environment: environment, timeout: timeout),
                !output.timedOut, output.status == 0 else { return nil }
            let blank = output.stdout.allSatisfy { $0 == 0x20 || $0 == 0x0A }
            return needsOutput && blank ? nil : label
        case .hostsFile(let relativePath, let keys, let label):
            let path = home + "/" + relativePath
            guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue <= Self.hostsFileLimit,
                  let data = fileManager.contents(atPath: path) else { return nil }
            return Self.hasYamlKey(String(decoding: data, as: UTF8.self), keys: keys) ? label : nil
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func take() -> Int? { lock.withLock { defer { value += 1 }; return value } }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Probe?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Probe) { lock.withLock { items[index] = value } }
        func get(_ index: Int) -> Probe? { lock.withLock { items[index] } }
    }
}
