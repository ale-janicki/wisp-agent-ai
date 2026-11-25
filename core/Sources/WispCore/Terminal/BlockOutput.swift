import Foundation

public struct BlockOutput: Equatable, Sendable {
    public static let maxLines = 100_000

    public private(set) var lines: [StyledLine]
    public private(set) var droppedLines: Int

    public init(lines: [StyledLine], droppedLines: Int = 0) {
        var kept = lines
        var dropped = droppedLines
        if kept.count > Self.maxLines {
            dropped += kept.count - Self.maxLines
            kept.removeFirst(kept.count - Self.maxLines)
        }
        self.lines = kept
        self.droppedLines = dropped
    }

    public static let empty = BlockOutput(lines: [])

    public var isEmpty: Bool { lines.allSatisfy { $0.text.isEmpty } }

    public var plainText: String {
        var texts = lines.map(\.text)
        while texts.last?.isEmpty == true { texts.removeLast() }
        return texts.joined(separator: "\n")
    }
}
