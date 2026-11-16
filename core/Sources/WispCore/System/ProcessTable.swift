import Foundation

public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var pid: Int32
    public var cpu: Double
    public var residentBytes: UInt64
    public var name: String

    public var id: Int32 { pid }

    public init(pid: Int32, cpu: Double, residentBytes: UInt64, name: String) {
        self.pid = pid
        self.cpu = cpu
        self.residentBytes = residentBytes
        self.name = name
    }
}

public enum ProcessTable {
    public static let command = ["/bin/ps", "-Aceo", "pid,%cpu,rss,comm"]

    public static func parse(_ output: String) -> [ProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> ProcessSample? in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(fields[2])
            else { return nil }
            let name = fields[3].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "ps" else { return nil }
            return ProcessSample(pid: pid, cpu: cpu, residentBytes: rss * 1024, name: name)
        }
    }

    public static func topByCPU(_ processes: [ProcessSample], count: Int = 5) -> [ProcessSample] {
        Array(processes.sorted { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) }.prefix(count))
    }

    public static func topByMemory(_ processes: [ProcessSample], count: Int = 5) -> [ProcessSample] {
        Array(processes.sorted { ($0.residentBytes, $1.pid) > ($1.residentBytes, $0.pid) }.prefix(count))
    }
}
