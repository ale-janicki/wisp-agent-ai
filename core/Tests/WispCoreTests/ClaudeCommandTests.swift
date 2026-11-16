import XCTest
@testable import WispCore

final class ClaudeCommandTests: XCTestCase {
    func testBareArguments() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        )
    }

    func testModelAndResume() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: "haiku", resume: "abc"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--model", "haiku", "--resume", "abc"]
        )
    }
}
