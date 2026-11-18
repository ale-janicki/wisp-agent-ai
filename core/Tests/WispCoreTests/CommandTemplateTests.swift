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

final class CommandTemplateRawTests: XCTestCase {
    func testRepeatedFlagQuotesEachValue() {
        XCTAssertEqual(CommandTemplate.repeated("--anexo", ["/a b.jpg", "/c'd.pdf"]), #"--anexo '/a b.jpg' --anexo '/c'\''d.pdf'"#)
        XCTAssertEqual(CommandTemplate.repeated("--anexo", []), "")
    }

    func testRawGoesInAsIsAndValuesCannotSmuggleOtherKeys() {
        let filled = CommandTemplate.fill("t {anexos} -- {thread} {text}", ["thread": "5", "text": "{anexos}"],
                                          raw: ["anexos": "--anexo '/x.jpg'"])
        XCTAssertEqual(filled, "t --anexo '/x.jpg' -- '5' '{anexos}'")
        XCTAssertEqual(CommandTemplate.fill("t {anexos} {text}", ["text": "oi"], raw: ["anexos": ""]), "t  'oi'")
    }
}
