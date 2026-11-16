import Foundation

public struct DayUsage: Equatable, Sendable {
    public var day: Date
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationTokens = 0
    public var cacheReadTokens = 0
    public var messages = 0

    public init(day: Date) {
        self.day = day
    }

    public var billableTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
    public var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

public struct UsageSummary: Equatable, Sendable {
    public var days: [DayUsage]

    public var today: DayUsage { days[days.count - 1] }
    public var billableTokens: Int { days.reduce(0) { $0 + $1.billableTokens } }
    public var cacheReadTokens: Int { days.reduce(0) { $0 + $1.cacheReadTokens } }
    public var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
}

public enum UsageAggregator {
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func aggregate(
        root: URL = defaultRoot,
        now: Date = Date(),
        calendar: Calendar = .current,
        days: Int = 7
    ) -> UsageSummary {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<max(1, days)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var summary = UsageSummary(days: starts.map(DayUsage.init(day:)))
        guard let windowStart = starts.first else { return summary }

        var seen = Set<String>()
        for file in transcripts(under: root, modifiedSince: windowStart) {
            forEachLine(of: file) { line in
                guard let entry = UsageEntry(line: line), !seen.contains(entry.id) else { return }
                let day = calendar.startOfDay(for: entry.timestamp)
                guard day >= windowStart, day <= today,
                      let index = calendar.dateComponents([.day], from: windowStart, to: day).day,
                      summary.days.indices.contains(index)
                else { return }
                seen.insert(entry.id)
                summary.days[index].inputTokens += entry.input
                summary.days[index].outputTokens += entry.output
                summary.days[index].cacheCreationTokens += entry.cacheCreation
                summary.days[index].cacheReadTokens += entry.cacheRead
                summary.days[index].messages += 1
            }
        }
        return summary
    }

    private static func transcripts(under root: URL, modifiedSince start: Date) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= start
            else { continue }
            files.append(url)
        }
        return files
    }

    private static let chunkSize = 1 << 18

    private static func forEachLine(of url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 0x0A) {
                if pending.isEmpty {
                    body(chunk[start..<newline])
                } else {
                    pending.append(chunk[start..<newline])
                    body(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                start = chunk.index(after: newline)
            }
            pending.append(chunk[start...])
        }
        if !pending.isEmpty { body(pending) }
    }
}

private struct UsageEntry {
    let id: String
    let timestamp: Date
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int

    private static let usageKey = Data("\"usage\"".utf8)
    private static let assistantKey = Data("\"assistant\"".utf8)

    init?(line: Data) {
        guard line.range(of: Self.usageKey) != nil, line.range(of: Self.assistantKey) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              message["model"] as? String != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let id = (message["id"] as? String) ?? (object["uuid"] as? String),
              let stamp = object["timestamp"] as? String,
              let timestamp = Self.date(stamp)
        else { return nil }
        func tokens(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        self.id = id
        self.timestamp = timestamp
        input = tokens("input_tokens")
        output = tokens("output_tokens")
        cacheCreation = tokens("cache_creation_input_tokens")
        cacheRead = tokens("cache_read_input_tokens")
    }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
