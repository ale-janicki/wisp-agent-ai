import XCTest
@testable import WispCore

final class StyledTextTests: XCTestCase {
    private let red = CellStyle(fg: .ansi(1))
    private let bold = CellStyle(bold: true)

    private func row(_ number: Int, _ pieces: [(String, CellStyle)], wrapped: Bool = false) -> StyledRow {
        StyledRow(row: number, line: StyledLine(pieces: pieces.map { (text: $0.0, style: $0.1) }), isWrapped: wrapped)
    }

    func testPiecesMergeNeighboursWithTheSameStyleAndCountUTF16() {
        let line = StyledLine(pieces: [("ab", red), ("c", red), ("é😀", bold), ("", red), ("z", .plain)])
        XCTAssertEqual(line.text, "abcé😀z")
        XCTAssertEqual(line.runs, [
            StyledRun(range: 0..<3, style: red), StyledRun(range: 3..<6, style: bold), StyledRun(range: 6..<7, style: .plain),
        ])
    }

    func testWrappedRowsJoinIntoOneLineWithShiftedRuns() {
        let lines = StyledLines.join(rows: [
            row(0, [("hello ", red), ("wor", bold)]),
            row(1, [("ld", bold)], wrapped: true),
            row(2, [("next", .plain)]),
        ])
        XCTAssertEqual(lines.map(\.text), ["hello world", "next"])
        XCTAssertEqual(lines[0].runs, [StyledRun(range: 0..<6, style: red), StyledRun(range: 6..<11, style: bold)])
    }

    func testTrailingBlanksGoAndTheRunsAreCutToMatch() {
        let lines = StyledLines.join(rows: [row(0, [("ab", red), ("  ", bold)]), row(1, [("   ", .plain)]), row(2, [("x ", red)])])
        XCTAssertEqual(lines.map(\.text), ["ab", "", "x"])
        XCTAssertEqual(lines[0].runs, [StyledRun(range: 0..<2, style: red)])
        XCTAssertEqual(lines[1].runs, [])
        XCTAssertEqual(lines[2].runs, [StyledRun(range: 0..<1, style: red)])
    }

    func testAWrappedRowAtTheStartIsALineOfItsOwn() {
        XCTAssertEqual(StyledLines.join(rows: [row(5, [("tail", .plain)], wrapped: true)]).map(\.text), ["tail"])
    }

    func testPaletteIndexPicksTheRightColorCase() {
        XCTAssertEqual(TermColor(paletteIndex: 3), .ansi(3))
        XCTAssertEqual(TermColor(paletteIndex: 15), .ansi(15))
        XCTAssertEqual(TermColor(paletteIndex: 16), .indexed(16))
        XCTAssertEqual(TermColor(paletteIndex: 255), .indexed(255))
    }

    func testPlainTextDropsTrailingBlankLines() {
        let output = BlockOutput(lines: ["a", "", "b", "", ""].map { StyledLine(text: $0) })
        XCTAssertEqual(output.plainText, "a\n\nb")
        XCTAssertFalse(output.isEmpty)
        XCTAssertTrue(BlockOutput(lines: [StyledLine(text: ""), StyledLine(text: "")]).isEmpty)
        XCTAssertEqual(BlockOutput.empty.plainText, "")
    }

    func testTheCapKeepsTheNewestLinesAndCountsWhatWentAway() {
        let lines = (0..<(BlockOutput.maxLines + 5)).map { StyledLine(text: "\($0)") }
        let output = BlockOutput(lines: lines, droppedLines: 2)
        XCTAssertEqual(output.lines.count, BlockOutput.maxLines)
        XCTAssertEqual(output.droppedLines, 7)
        XCTAssertEqual(output.lines.first?.text, "5")
        XCTAssertEqual(output.lines.last?.text, "\(BlockOutput.maxLines + 4)")
    }
}
