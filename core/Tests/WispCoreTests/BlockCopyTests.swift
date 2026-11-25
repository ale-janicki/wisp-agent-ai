import XCTest
@testable import WispCore

final class BlockCopyTests: XCTestCase {
    func testEachPartCopiesWhatItNames() {
        XCTAssertEqual(BlockCopy.command.text(command: "ls -la", output: "a\nb"), "ls -la")
        XCTAssertEqual(BlockCopy.output.text(command: "ls -la", output: "a\nb"), "a\nb")
        XCTAssertEqual(BlockCopy.commandAndOutput.text(command: "ls -la", output: "a\nb"), "ls -la\na\nb")
    }

    func testNoBlankLineWhenOneSideIsEmpty() {
        XCTAssertEqual(BlockCopy.commandAndOutput.text(command: "true", output: ""), "true")
        XCTAssertEqual(BlockCopy.commandAndOutput.text(command: "", output: "out"), "out")
    }

    func testCommandKeepsItsInnerLinesButNotTrailingNewlines() {
        XCTAssertEqual(BlockCopy.command.text(command: "echo a\necho b\n\n", output: ""), "echo a\necho b")
        XCTAssertEqual(BlockCopy.commandAndOutput.text(command: "echo a\necho b\n", output: "a\nb"), "echo a\necho b\na\nb")
    }
}
