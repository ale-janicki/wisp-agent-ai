import Foundation

public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    public mutating func flush() -> String? {
        defer { pending = Data() }
        guard let line = String(data: pending, encoding: .utf8), !line.isEmpty else { return nil }
        return line
    }
}
