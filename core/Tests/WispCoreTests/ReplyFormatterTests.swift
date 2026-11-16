import XCTest
@testable import WispCore

final class ReplyFormatterTests: XCTestCase {
    func testSplitsStatusBlock() {
        let parts = ReplyFormatter.split("oi\n\nSTATUS · x · y\nTeu: z", statusPrefix: "STATUS ·")
        XCTAssertEqual(parts.body, "oi")
        XCTAssertEqual(parts.status, "x · y")
    }

    func testNoPrefixKeepsAll() {
        let parts = ReplyFormatter.split("oi\n\nSTATUS · x · y", statusPrefix: nil)
        XCTAssertEqual(parts.body, "oi\n\nSTATUS · x · y")
        XCTAssertNil(parts.status)
    }

    func testPrefixAbsentKeepsAll() {
        let parts = ReplyFormatter.split("oi", statusPrefix: "STATUS ·")
        XCTAssertEqual(parts.body, "oi")
        XCTAssertNil(parts.status)
    }

    func testCrlfStatusSplit() {
        let parts = ReplyFormatter.split("oi\r\n\r\nSTATUS · x · y\r\nTeu: z", statusPrefix: "STATUS ·")
        XCTAssertEqual(parts.body, "oi")
        XCTAssertEqual(parts.status, "x · y")
    }
}
