import Foundation

public struct RoutinesBlock: Codable, Sendable, Equatable {
    public var registry: String?
    public var status: String?
    public var start: String?
    public var stop: String?

    public init(registry: String? = nil, status: String? = nil, start: String? = nil, stop: String? = nil) {
        self.registry = registry
        self.status = status
        self.start = start
        self.stop = stop
    }
}

public struct RoutineJob: Codable, Identifiable, Equatable, Sendable {
    public var label: String
    public var name: String
    public var description: String?
    public var plist: String
    public var logs: [String]

    public var id: String { label }

    public init(label: String, name: String, description: String? = nil, plist: String, logs: [String] = []) {
        self.label = label
        self.name = name
        self.description = description
        self.plist = plist
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey { case label, name, description, plist, logs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? label
        description = try container.decodeIfPresent(String.self, forKey: .description)
        plist = try container.decode(String.self, forKey: .plist)
        logs = try container.decodeIfPresent([String].self, forKey: .logs) ?? []
    }
}

public enum RoutineRegistryError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case invalid

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "não consegui ler \(path)"
        case .invalid: "o registro de rotinas não está no formato {\"jobs\": [...]}"
        }
    }
}

public enum RoutineRegistry {
    private struct File: Decodable { var jobs: [RoutineJob] }

    public static func parse(_ data: Data) throws -> [RoutineJob] {
        do {
            return try JSONDecoder().decode(File.self, from: data).jobs.map { job in
                var job = job
                job.plist = expandTilde(job.plist)
                job.logs = job.logs.map(expandTilde)
                return job
            }
        } catch {
            throw RoutineRegistryError.invalid
        }
    }

    public static func load(path: String) throws -> [RoutineJob] {
        let expanded = expandTilde(path)
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw RoutineRegistryError.unreadable(path)
        }
        return try parse(data)
    }

    public static func logs(fromPlist data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        var logs: [String] = []
        for key in ["StandardOutPath", "StandardErrorPath"] {
            guard let raw = plist[key] as? String, !raw.isEmpty else { continue }
            let path = expandTilde(raw)
            if !logs.contains(path) { logs.append(path) }
        }
        return logs
    }
}

public struct RoutineStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case waiting
        case unloaded
        case other(String)
    }

    public var state: State
    public var pid: Int32?
    public var runs: Int?
    public var lastExitCode: Int32?
    public var lastExitReason: String?

    public var isLoaded: Bool { state != .unloaded }
    public var lastRunFailed: Bool { (lastExitCode ?? 0) != 0 }

    public init(state: State, pid: Int32? = nil, runs: Int? = nil, lastExitCode: Int32? = nil, lastExitReason: String? = nil) {
        self.state = state
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.lastExitReason = lastExitReason
    }

    public static let unloaded = RoutineStatus(state: .unloaded)
}

public enum RoutineStatusParser {
    public static let notLoadedExitCode: Int32 = 113

    public static func parse(_ text: String) -> RoutineStatus? {
        var fields: [String: String] = [:]
        var sawHeader = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !sawHeader {
                if line.hasSuffix("= {"), !line.hasPrefix("\t") { sawHeader = true }
                continue
            }
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let range = body.range(of: " = ") else { continue }
            let key = String(body[..<range.lowerBound])
            if fields[key] == nil { fields[key] = String(body[range.upperBound...]) }
        }
        guard sawHeader, let rawState = fields["state"] else { return nil }

        let state: RoutineStatus.State = switch rawState {
        case "running": .running
        case "not running", "waiting": .waiting
        default: .other(rawState)
        }
        var status = RoutineStatus(state: state)
        status.pid = fields["pid"].flatMap { Int32($0) }
        status.runs = fields["runs"].flatMap { Int($0) }
        if let exit = fields["last exit code"] {
            let parts = exit.split(separator: ":", maxSplits: 1)
            status.lastExitCode = parts.first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            status.lastExitReason = reason.isEmpty ? nil : reason
        }
        return status
    }

    public static func interpret(_ result: Result<Data, BlockCommandError>) -> Result<RoutineStatus, RoutineStatusError> {
        switch result {
        case .success(let data):
            guard let status = parse(String(decoding: data, as: UTF8.self)) else {
                return .failure(RoutineStatusError("a saída do status não é a do launchctl print"))
            }
            return .success(status)
        case .failure(.failed(let code, _)) where code == notLoadedExitCode:
            return .success(.unloaded)
        case .failure(let error):
            return .failure(RoutineStatusError(error.localizedDescription))
        }
    }
}

public struct RoutineStatusError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}

public enum RoutineCommand {
    public static func build(_ template: String, job: RoutineJob, uid: uid_t = getuid()) -> String {
        template
            .replacingOccurrences(of: "{label}", with: MemorySearch.shellQuote(job.label))
            .replacingOccurrences(of: "{plist}", with: MemorySearch.shellQuote(job.plist))
            .replacingOccurrences(of: "{uid}", with: String(uid))
    }
}

public enum LogTail {
    public enum Failure: Error, Equatable, LocalizedError {
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let path): "o log \(path) não existe"
            }
        }
    }

    public static func read(path: String, count: Int = 50, maxBytes: Int = 64 * 1024) -> Result<[String], Failure> {
        guard let handle = FileHandle(forReadingAtPath: expandTilde(path)) else { return .failure(.missing(path)) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return .success(lastLines(of: data, count: count, truncatedStart: start > 0))
    }

    static func lastLines(of data: Data, count: Int, truncatedStart: Bool) -> [String] {
        var lines = String(decoding: data, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map(String.init)
        if truncatedStart, !lines.isEmpty { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(count))
    }
}
