import Foundation

public enum TermColor: Equatable, Hashable, Sendable {
    case `default`
    case ansi(Int)
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)

    public init(paletteIndex code: Int) {
        self = code < 0 ? .default : code < 16 ? .ansi(code) : .indexed(min(code, 255))
    }
}

public struct CellStyle: Equatable, Hashable, Sendable {
    public var fg = TermColor.default
    public var bg = TermColor.default
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strike = false

    public static let plain = CellStyle()

    public init(
        fg: TermColor = .default, bg: TermColor = .default, bold: Bool = false, dim: Bool = false, italic: Bool = false,
        underline: Bool = false, inverse: Bool = false, strike: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strike = strike
    }
}

public struct StyledRun: Equatable, Sendable {
    public var range: Range<Int>
    public var style: CellStyle

    public init(range: Range<Int>, style: CellStyle) {
        self.range = range
        self.style = style
    }
}

public struct StyledLine: Equatable, Sendable {
    public var text: String
    public var runs: [StyledRun]

    public init(text: String, runs: [StyledRun] = []) {
        self.text = text
        self.runs = runs
    }

    public static let empty = StyledLine(text: "")

    public init(pieces: [(text: String, style: CellStyle)]) {
        var text = ""
        var runs = [StyledRun]()
        var offset = 0
        for piece in pieces where !piece.text.isEmpty {
            let length = piece.text.utf16.count
            text += piece.text
            if let last = runs.last, last.style == piece.style {
                runs[runs.count - 1].range = last.range.lowerBound..<(offset + length)
            } else {
                runs.append(StyledRun(range: offset..<(offset + length), style: piece.style))
            }
            offset += length
        }
        self.init(text: text, runs: runs)
    }

    public func trimmed() -> StyledLine {
        if let last = text.utf8.last, last != 0x20, last != 0x09 { return self }
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
            end = text.index(before: end)
        }
        guard end != text.endIndex else { return self }
        let kept = text[..<end].utf16.count
        let runs = runs.compactMap { run -> StyledRun? in
            guard run.range.lowerBound < kept else { return nil }
            return StyledRun(range: run.range.lowerBound..<min(run.range.upperBound, kept), style: run.style)
        }
        return StyledLine(text: String(text[..<end]), runs: runs)
    }

    func appending(_ other: StyledLine) -> StyledLine {
        let shift = text.utf16.count
        var runs = self.runs
        for run in other.runs {
            let moved = StyledRun(range: (run.range.lowerBound + shift)..<(run.range.upperBound + shift), style: run.style)
            if let last = runs.last, last.style == moved.style, last.range.upperBound == moved.range.lowerBound {
                runs[runs.count - 1].range = last.range.lowerBound..<moved.range.upperBound
            } else {
                runs.append(moved)
            }
        }
        return StyledLine(text: text + other.text, runs: runs)
    }
}

public struct StyledRow: Equatable, Sendable {
    public var row: Int
    public var line: StyledLine
    public var isWrapped: Bool

    public init(row: Int, line: StyledLine, isWrapped: Bool) {
        self.row = row
        self.line = line
        self.isWrapped = isWrapped
    }
}

public enum StyledLines {
    public static func join(rows: [StyledRow]) -> [StyledLine] {
        var lines = [StyledLine]()
        for row in rows {
            if row.isWrapped, let last = lines.last {
                lines[lines.count - 1] = last.appending(row.line)
            } else {
                lines.append(row.line)
            }
        }
        return lines.map { $0.trimmed() }
    }
}
