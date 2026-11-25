import AppKit
import SwiftTerm
import WispCore

enum SwiftTermStyle {
    // MARK: Screen to styled text

    static func cellStyle(_ attribute: Attribute) -> CellStyle {
        let flags = attribute.style
        return CellStyle(
            fg: color(attribute.fg), bg: color(attribute.bg), bold: flags.contains(.bold), dim: flags.contains(.dim),
            italic: flags.contains(.italic), underline: flags.contains(.underline) || attribute.underlineStyle != .none,
            inverse: flags.contains(.inverse), strike: flags.contains(.crossedOut))
    }

    private static func color(_ color: Attribute.Color) -> TermColor {
        switch color {
        case .ansi256(let code): TermColor(paletteIndex: Int(code))
        case .trueColor(let red, let green, let blue): .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: .default
        }
    }

    static func styledRow(_ row: TerminalContentRowSnapshot) -> StyledRow {
        let cells = row.cells
        guard let last = cells.lastIndex(where: { !$0.isBlank }) else {
            return StyledRow(row: row.absoluteRow, line: .empty, isWrapped: row.isWrapped)
        }
        var text = ""
        text.reserveCapacity(last + 1)
        var runs = [StyledRun]()
        var attribute: Attribute?
        var style = CellStyle.plain
        var runStart = 0
        var offset = 0
        for index in 0...last {
            let cell = cells[index]
            let blank = cell.isBlank
            if blank, index > 0, cells[index - 1].width == 2 { continue }
            if attribute != cell.attribute {
                attribute = cell.attribute
                let next = cellStyle(cell.attribute)
                if next != style {
                    if offset > runStart { runs.append(StyledRun(range: runStart..<offset, style: style)) }
                    style = next
                    runStart = offset
                }
            }
            if blank {
                text += " "
                offset += 1
            } else {
                let cellText = cell.text
                text += cellText
                offset += cellText.utf16.count
            }
        }
        if offset > runStart { runs.append(StyledRun(range: runStart..<offset, style: style)) }
        return StyledRow(row: row.absoluteRow, line: StyledLine(text: text, runs: runs), isWrapped: row.isWrapped)
    }

    static func capture(_ view: TerminalView, rows range: Range<Int>) -> BlockOutput {
        guard !range.isEmpty else { return .empty }
        guard let oldest = view.terminalContentSnapshot(region: .rows(0..<0), buffer: .normal)?.capturedRange.lowerBound else {
            return .empty
        }
        var styled = [StyledRow]()
        var first: Int?
        var next = max(range.lowerBound, oldest)
        while next < range.upperBound {
            let end = min(next + chunkRows, range.upperBound)
            guard let snapshot = view.terminalContentSnapshot(region: .rows(next..<end), buffer: .normal) else { break }
            if first == nil { first = snapshot.rows.first?.absoluteRow }
            styled.reserveCapacity(styled.count + snapshot.rows.count)
            for row in snapshot.rows { styled.append(styledRow(row)) }
            next = end
        }
        let dropped = (first ?? range.upperBound) - range.lowerBound
        var lines = StyledLines.join(rows: styled)
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return BlockOutput(lines: lines, droppedLines: max(0, dropped))
    }

    private static let chunkRows = 1_000

    // MARK: Styled text to attributed string

    @MainActor
    static func attributed(_ lines: [StyledLine], font: NSFont, colors: ThemeColors) -> NSAttributedString {
        let normal = TerminalTheme.ns(colors.textPrimary)
        let ground = TerminalTheme.ns(colors.background)
        let bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: normal, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let piece = NSMutableAttributedString(string: line.text + (index < lines.count - 1 ? "\n" : ""), attributes: base)
            for run in line.runs where run.range.upperBound <= line.text.utf16.count {
                var attributes = [NSAttributedString.Key: Any]()
                var fg = resolve(run.style.fg, fallback: normal)
                var bg: NSColor? = run.style.bg == .default ? nil : resolve(run.style.bg, fallback: ground)
                if run.style.inverse {
                    (fg, bg) = (bg ?? ground, fg)
                }
                if run.style.dim { fg = fg.withAlphaComponent(0.6) }
                if fg != normal { attributes[.foregroundColor] = fg }
                if let bg { attributes[.backgroundColor] = bg }
                if run.style.bold { attributes[.font] = bold }
                if run.style.italic { attributes[.obliqueness] = 0.2 }
                if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if !attributes.isEmpty {
                    piece.addAttributes(attributes, range: NSRange(location: run.range.lowerBound, length: run.range.count))
                }
            }
            result.append(piece)
        }
        return result
    }

    @MainActor
    private static func resolve(_ color: TermColor, fallback: NSColor) -> NSColor {
        switch color {
        case .default: fallback
        case .ansi(let index): TerminalTheme.ns(hex: TerminalTheme.palette[min(max(index, 0), 15)])
        case .indexed(let index): indexed(index)
        case .rgb(let red, let green, let blue):
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private static func indexed(_ index: Int) -> NSColor {
        func level(_ step: Int) -> CGFloat { step == 0 ? 0 : CGFloat(55 + 40 * step) / 255 }
        if index >= 232 {
            let gray = CGFloat(8 + 10 * (min(index, 255) - 232)) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
        let cube = max(index, 16) - 16
        return NSColor(srgbRed: level(cube / 36), green: level(cube / 6 % 6), blue: level(cube % 6), alpha: 1)
    }
}
