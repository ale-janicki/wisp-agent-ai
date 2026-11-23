import XCTest
@testable import WispCore

final class ClaudeCommandTests: XCTestCase {
    func testBareArguments() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--permission-prompt-tool", "stdio"]
        )
    }

    func testModelAndResume() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: "haiku", resume: "abc"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--model", "haiku", "--resume", "abc", "--permission-prompt-tool", "stdio"]
        )
    }

    func testPermissionMode() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil, permissionMode: "auto"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--permission-mode", "auto", "--permission-prompt-tool", "stdio"]
        )
    }

    func testAppendSystemPromptGoesBeforeThePermissionPromptTool() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: "abc", permissionMode: nil, appendSystemPrompt: "regras"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--resume", "abc", "--append-system-prompt", "regras", "--permission-prompt-tool", "stdio"]
        )
    }

    func testSettingsGoBeforeThePermissionPromptTool() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: nil, settings: "/s/guards.json"),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--settings", "/s/guards.json", "--permission-prompt-tool", "stdio"]
        )
    }
}
