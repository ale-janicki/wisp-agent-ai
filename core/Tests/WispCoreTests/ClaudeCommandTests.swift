import XCTest
@testable import WispCore

final class ClaudeCommandTests: XCTestCase {
    func testBareArguments() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--permission-prompt-tool", "stdio"]
        )
    }

    func testModelAndResume() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: "haiku", resume: "abc"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--model", "haiku", "--resume", "abc", "--permission-prompt-tool", "stdio"]
        )
    }

    func testPermissionMode() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil, permissionMode: "auto"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
             "--permission-mode", "auto", "--permission-prompt-tool", "stdio"]
        )
    }
}
