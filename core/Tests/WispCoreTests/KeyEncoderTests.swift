import XCTest
@testable import WispCore

final class KeyEncoderTests: XCTestCase {
    func testTextIsUTF8() {
        XCTAssertEqual(KeyEncoder.bytes(.text("a")), [0x61])
        XCTAssertEqual(KeyEncoder.bytes(.text("ç")), Array("ç".utf8))
        XCTAssertEqual(KeyEncoder.bytes(.text("😀")), Array("😀".utf8))
    }

    func testSpecialKeys() {
        XCTAssertEqual(KeyEncoder.bytes(.enter), [0x0D])
        XCTAssertEqual(KeyEncoder.bytes(.backspace), [0x7F])
        XCTAssertEqual(KeyEncoder.bytes(.tab), [0x09])
        XCTAssertEqual(KeyEncoder.bytes(.escape), [0x1B])
    }

    func testControlLetters() {
        XCTAssertEqual(KeyEncoder.bytes(.text("c"), control: true), [0x03])
        XCTAssertEqual(KeyEncoder.bytes(.text("D"), control: true), [0x04])
        XCTAssertEqual(KeyEncoder.bytes(.text("z"), control: true), [0x1A])
        XCTAssertEqual(KeyEncoder.bytes(.text("["), control: true), [0x1B])
        XCTAssertEqual(KeyEncoder.bytes(.text("\\"), control: true), [0x1C])
        XCTAssertEqual(KeyEncoder.bytes(.text(" "), control: true), [0x00])
        XCTAssertEqual(KeyEncoder.bytes(.text("?"), control: true), [0x7F])
    }

    func testControlWithSomethingElseSendsTheText() {
        XCTAssertEqual(KeyEncoder.bytes(.text("1"), control: true), [0x31])
        XCTAssertEqual(KeyEncoder.bytes(.text("ab"), control: true), [0x61, 0x62])
        XCTAssertEqual(KeyEncoder.bytes(.enter, control: true), [0x0D])
    }

    func testArrowsInNormalAndApplicationCursorForm() {
        let keys: [(TerminalKey, String)] = [(.up, "A"), (.down, "B"), (.right, "C"), (.left, "D")]
        for (key, letter) in keys {
            XCTAssertEqual(KeyEncoder.bytes(key), Array("\u{1B}[\(letter)".utf8))
            XCTAssertEqual(KeyEncoder.bytes(key, applicationCursor: true), Array("\u{1B}O\(letter)".utf8))
        }
    }
}
