import Foundation

public struct LearnedLessons: Sendable {
    public struct Lesson: Equatable, Identifiable, Sendable {
        public let index: Int
        public let line: String
        public let rule: String
        public let date: String?
        public let origin: String?

        public var id: String { "\(index)|\(line)" }
        public var learnedAlone: Bool { origin == LearnedLessons.harvestOrigin }

        init?(index: Int, raw: String) {
            guard raw.hasPrefix("- ") else { return nil }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.dropFirst(2).components(separatedBy: LearnedLessons.separator)
            let rule = parts[0].trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty else { return nil }
            self.index = index
            self.line = line
            self.rule = rule
            date = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            origin = parts.count > 2 ? parts[2...].joined(separator: LearnedLessons.separator).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    static let separator = " · "
    static let harvestOrigin = "colheita"
    public static let relativePath = "wisp/aprendizados.md"
    public static let defaultLock = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/wisp/aprendizados.lock")

    public let url: URL
    public let lock: URL

    public init(brain: URL, lock: URL = LearnedLessons.defaultLock) {
        url = brain.appendingPathComponent(LearnedLessons.relativePath)
        self.lock = lock
    }

    public func lessons() -> [Lesson] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").enumerated().compactMap { Lesson(index: $0.offset, raw: $0.element) }
    }

    @discardableResult
    public func remove(_ lesson: Lesson) throws -> Bool {
        try withLock {
            let text = try String(contentsOf: url, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.hasPrefix("- ") && $0.trimmingCharacters(in: .whitespaces) == lesson.line }) else { return false }
            lines.remove(at: index)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
