import Foundation

public enum SetupStepID: String, CaseIterable, Sendable {
    case system, login, brain, harness, telegram, spotify, profile, done
}

public struct SetupDetail: Decodable, Sendable, Equatable {
    public var command: String
    public var exit: Int32
    public var output: String

    public init(command: String, exit: Int32, output: String) {
        self.command = command
        self.exit = exit
        self.output = output
    }
}

/// One `wisp setup <step> --json` result.
public struct SetupReport: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable { case done, skipped, needsUser = "needs_user", failed }

    public var step: String
    public var status: Status
    public var summary: String
    public var details: [SetupDetail]
    public var data: [String: String]

    public init(step: String, status: Status, summary: String, details: [SetupDetail] = [], data: [String: String] = [:]) {
        self.step = step
        self.status = status
        self.summary = summary
        self.details = details
        self.data = data
    }
}

public struct DoctorCheck: Decodable, Sendable, Equatable {
    public var id: String
    public var ok: Bool
    public var summary: String
    public var step: String?

    public init(id: String, ok: Bool, summary: String, step: String? = nil) {
        self.id = id
        self.ok = ok
        self.summary = summary
        self.step = step
    }
}

public struct DoctorReport: Decodable, Sendable, Equatable {
    public var version: Int
    public var checks: [DoctorCheck]

    public init(version: Int, checks: [DoctorCheck]) {
        self.version = version
        self.checks = checks
    }
}

/// `~/Library/Application Support/Wisp/setup.json`.
public struct SetupState: Codable, Sendable, Equatable {
    public var completed: Set<String>
    public var skipped: Set<String>
    public var finishedAt: Date?

    public init(completed: Set<String> = [], skipped: Set<String> = [], finishedAt: Date? = nil) {
        self.completed = completed
        self.skipped = skipped
        self.finishedAt = finishedAt
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// nil when the file does not exist (a fresh Mac); a file that exists but does not decode throws.
    public static func load(from url: URL) throws -> SetupState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(SetupState.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }
}
