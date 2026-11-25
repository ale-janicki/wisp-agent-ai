import Foundation

public enum HistoryFormat: Equatable, Sendable {
    case zshExtended
    case plain
    case fish
}

public enum HistoryParser {
    public static func defaultFile(shellName: String, home: String, environment: [String: String] = [:]) -> String? {
        switch shellName {
        case "zsh": return ((environment["ZDOTDIR"] ?? home) as NSString).appendingPathComponent(".zsh_history")
        case "bash": return (home as NSString).appendingPathComponent(".bash_history")
        case "fish":
            let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".local/share")
            return (data as NSString).appendingPathComponent("fish/fish_history")
        default: return nil
        }
    }

    public static func detect(_ text: String) -> HistoryFormat {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(50) {
            if extendedPrefix(line) != nil { return .zshExtended }
            if line.hasPrefix("- cmd: ") { return .fish }
        }
        return .plain
    }

    public static func load(path: String, metafied: Bool, limit: Int = 50_000, tailBytes: Int = 4_000_000) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data.suffix(from: newline + 1) }
        let entries = parse(metafied ? unmetafy(data) : String(decoding: data, as: UTF8.self))
        return entries.count > limit ? Array(entries.suffix(limit)) : entries
    }

    public static func parse(_ text: String, format: HistoryFormat? = nil) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var entries = [String]()
        func add(_ entry: String) {
            guard !entry.trimmingCharacters(in: .whitespaces).isEmpty, entries.last != entry else { return }
            entries.append(entry)
        }
        switch format ?? detect(text) {
        case .fish:
            for line in lines where line.hasPrefix("- cmd: ") { add(unescapeFish(String(line.dropFirst(7)))) }
        case .zshExtended, .plain:
            var index = 0
            while index < lines.count {
                var line = Substring(lines[index])
                index += 1
                if let body = extendedPrefix(line) {
                    line = body
                } else if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber), line.count > 1 {
                    continue
                }
                var entry = String(line)
                while continues(entry), index < lines.count {
                    entry.removeLast()
                    entry += "\n" + lines[index]
                    index += 1
                }
                add(entry)
            }
        }
        return entries
    }

    private static func extendedPrefix(_ line: Substring) -> Substring? {
        guard line.hasPrefix(": ") else { return nil }
        let rest = line.dropFirst(2)
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        let head = rest[rest.startIndex..<semicolon].split(separator: ":", omittingEmptySubsequences: false)
        guard head.count == 2, head.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return rest[rest.index(after: semicolon)...]
    }

    private static func continues(_ entry: String) -> Bool {
        var count = 0
        for character in entry.reversed() {
            guard character == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    private static func unescapeFish(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                out.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    static func unmetafy(_ data: Data) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count)
        var iterator = data.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x83, let next = iterator.next() { bytes.append(next ^ 0x20) } else { bytes.append(byte) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public final class CommandHistory: @unchecked Sendable {
    public static let shared = CommandHistory()

    public let capacity: Int
    private let lock = NSLock()
    private var storage = [String]()
    private var seeded = false
    private var seeding = false

    public init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
    }

    public var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func seed(with loaded: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard !seeded else { return }
        seeded = true
        seeding = false
        var merged = [String]()
        for entry in loaded + storage where merged.last != entry { merged.append(entry) }
        storage = merged.count > capacity ? Array(merged.suffix(capacity)) : merged
    }

    public func claimSeed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !seeded, !seeding else { return false }
        seeding = true
        return true
    }

    public func releaseSeed() {
        lock.lock()
        seeding = false
        lock.unlock()
    }

    public var isSeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seeded
    }

    public func append(_ command: String) {
        let text = command.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard storage.last != text else { return }
        storage.append(text)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public func search(_ query: String, limit: Int = 200) -> [String] {
        let all = entries
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<String>()
        var contained = [String]()
        var scattered = [String]()
        for entry in all.reversed() where seen.insert(entry).inserted {
            if words.isEmpty {
                contained.append(entry)
            } else {
                let lowered = entry.lowercased()
                if words.allSatisfy({ lowered.contains($0) }) {
                    contained.append(entry)
                } else if words.allSatisfy({ Self.isSubsequence($0, of: lowered) }) {
                    scattered.append(entry)
                }
            }
            if contained.count >= limit { break }
        }
        return Array((contained + scattered).prefix(limit))
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var wanted = needle.makeIterator()
        var next = wanted.next()
        for character in haystack {
            guard let target = next else { return true }
            if character == target { next = wanted.next() }
        }
        return next == nil
    }
}

public struct HistoryNavigator: Equatable, Sendable {
    public private(set) var position: Int?
    private var draft = ""
    private var prefix = ""

    public init() {}

    public var isNavigating: Bool { position != nil }

    public mutating func reset() {
        position = nil
        draft = ""
        prefix = ""
    }

    public mutating func back(entries: [String], current: String) -> String? {
        if position == nil {
            draft = current
            prefix = current
        }
        var index = (position ?? entries.count) - 1
        while index >= 0 {
            let candidate = entries[index]
            if candidate.hasPrefix(prefix), candidate != current {
                position = index
                return candidate
            }
            index -= 1
        }
        return nil
    }

    public mutating func forward(entries: [String], current: String) -> String? {
        guard let position else { return nil }
        var index = position + 1
        while index < entries.count {
            let candidate = entries[index]
            if candidate.hasPrefix(prefix), candidate != current {
                self.position = index
                return candidate
            }
            index += 1
        }
        let restored = draft
        reset()
        return restored
    }
}
