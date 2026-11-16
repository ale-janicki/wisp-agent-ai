import XCTest
@testable import WispCore

final class CommandTemplateTests: XCTestCase {
    func testQuotesEachValueAsOneWord() {
        XCTAssertEqual(CommandTemplate.fill("tool resolve {id}", ["id": "a-b"]), "tool resolve 'a-b'")
        XCTAssertEqual(CommandTemplate.fill("tool {id}", ["id": "x'; rm -rf ~; '"]), #"tool 'x'\''; rm -rf ~; '\'''"#)
        XCTAssertEqual(CommandTemplate.fill("tool", ["id": "a"]), "tool")
    }

    func testQuotedValueRunsAsOneArgument() {
        let tricky = "a b'c $(echo no)"
        let result = BlockCommand.run(CommandTemplate.fill("printf %s {v}", ["v": tricky]), path: "/usr/bin:/bin")
        XCTAssertEqual(try result.get(), Data(tricky.utf8))
    }
}
