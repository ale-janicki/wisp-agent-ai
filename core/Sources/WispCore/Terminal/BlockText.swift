import Foundation

public struct ScreenRow: Equatable, Sendable {
    public var row: Int
    public var text: String
    public var isWrapped: Bool

    public init(row: Int, text: String, isWrapped: Bool) {
        self.row = row
        self.text = text
        self.isWrapped = isWrapped
    }
}

public enum BlockCopy: CaseIterable, Sendable {
    case command, output, commandAndOutput

    public func text(command: String, output: String) -> String {
        var typed = command
        while typed.last == "\n" { typed.removeLast() }
        switch self {
        case .command: return typed
        case .output: return output
        case .commandAndOutput: return [typed, output].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

extension BlockCopy {
    public func text(blocks: [(command: String, output: String)]) -> String {
        blocks.map { text(command: $0.command, output: $0.output) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public enum BlockText {
    struct Line: Equatable {
        var firstRow: Int
        var text: String
    }

    static func lines(_ rows: [ScreenRow]) -> [Line] {
        var result = [Line]()
        for row in rows {
            if row.isWrapped, !result.isEmpty {
                result[result.count - 1].text += row.text
            } else {
                result.append(Line(firstRow: row.row, text: row.text))
            }
        }
        return result.map { Line(firstRow: $0.firstRow, text: trimmed($0.text)) }
    }

    private static func trimmed(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }

    public static func lineCount(_ rows: [ScreenRow]) -> Int {
        max(1, rows.filter { !$0.isWrapped }.count)
    }

    public static func output(_ rows: [ScreenRow]) -> String {
        var texts = lines(rows).map(\.text)
        while texts.last?.isEmpty == true { texts.removeLast() }
        return texts.joined(separator: "\n")
    }

    public static func reanchor(_ blocks: [TerminalBlock], rows: [ScreenRow]) -> [TerminalBlock] {
        let all = lines(rows)
        guard let lastFilled = all.lastIndex(where: { !$0.text.isEmpty }) else { return [] }
        let candidates = blocks.enumerated().map { promptLines(of: $0.element, in: all, firstBlock: $0.offset == 0) }
        var found = [(block: TerminalBlock, promptRow: Int, outputStart: Int)]()
        var cursor = 0
        for (index, block) in blocks.enumerated() {
            guard let hit = candidates[index].first(where: { $0 >= cursor }) else { continue }
            let limit = index + 1 < blocks.count ? (candidates[index + 1].first { $0 > hit } ?? all.count) : all.count
            let start = cursor
            cursor = hit + 1
            guard candidates[index].filter({ $0 >= start && $0 < limit }).count == 1 else { continue }
            let commandLines = commandLines(of: block).count
            let head = max(commandLines, block.headLines)
            let first = max(start, hit - (head - commandLines))
            let afterHead = first + head
            guard afterHead < all.count || block.isRunning else { continue }
            let output = afterHead < all.count ? all[afterHead].firstRow : all[hit].firstRow + 1
            found.append((block, all[first].firstRow, output))
            cursor = hit + commandLines
        }
        var result = [TerminalBlock]()
        for (index, entry) in found.enumerated() {
            var block = entry.block
            block.promptRow = entry.promptRow
            block.outputStart = max(entry.outputStart, entry.promptRow)
            if block.isRunning {
                block.outputEnd = nil
            } else {
                let next = index + 1 < found.count ? found[index + 1].promptRow : all[lastFilled].firstRow
                block.outputEnd = max(block.outputStart, next - 1)
            }
            result.append(block)
        }
        return result
    }

    private static func commandLines(of block: TerminalBlock) -> [String] {
        let lines = block.command.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.isEmpty ? [""] : lines
    }

    private static func promptLines(of block: TerminalBlock, in all: [Line], firstBlock: Bool) -> [Int] {
        let command = commandLines(of: block)
        guard let needle = command.first, !needle.isEmpty else { return [] }
        let promptOnly = max(0, block.headLines - command.count)
        return all.indices.filter { index in
            guard all[index].text.hasSuffix(needle), index + command.count <= all.count else { return false }
            for offset in 1..<max(1, command.count) where !command[offset].isEmpty {
                guard all[index + offset].text.hasSuffix(command[offset]) else { return false }
            }
            let first = index - promptOnly
            guard first >= 0 else { return false }
            return firstBlock || first == 0 || all[first - 1].text.isEmpty
        }
    }

    public static func merge(reanchored: [TerminalBlock], snapshot: [TerminalBlock], current: [TerminalBlock]) -> [TerminalBlock] {
        let placed = Dictionary(reanchored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(snapshot.map(\.id))
        let runningThen = Set(snapshot.filter(\.isRunning).map(\.id))
        return current.compactMap { block in
            guard known.contains(block.id) else { return block }
            guard let moved = placed[block.id] else { return nil }
            var merged = block
            merged.promptRow = moved.promptRow
            merged.outputStart = moved.outputStart
            if !runningThen.contains(block.id) { merged.outputEnd = moved.outputEnd }
            return merged
        }
    }
}
