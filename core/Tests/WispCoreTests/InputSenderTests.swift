import XCTest
@testable import WispCore

final class InputSenderTests: XCTestCase {
    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testBracketedPasteBetweenClearLineAndEnter() {
        let bytes = InputSender.bytes(text: "ls -G", bracketedPaste: true)
        XCTAssertEqual(text(bytes), "\u{05}\u{15}\u{1B}[200~ls -G\u{1B}[201~\r")
    }

    func testWithoutBracketedPasteTheTextIsTypedAsIs() {
        XCTAssertEqual(text(InputSender.bytes(text: "git status", bracketedPaste: false)), "\u{05}\u{15}git status\r")
    }

    func testControlCharactersCannotEndThePasteOrPressKeys() {
        let bytes = InputSender.bytes(text: "echo hi\u{1B}[201~\u{03}; rm x\u{7F}", bracketedPaste: true)
        XCTAssertEqual(text(bytes), "\u{05}\u{15}\u{1B}[200~echo hi[201~; rm x\u{1B}[201~\r")
        XCTAssertEqual(bytes.filter { $0 == 0x1B }.count, 2, "only the paste's own two escapes")
    }

    func testTrailingNewlinesGoButInnerOnesStay() {
        XCTAssertEqual(text(InputSender.bytes(text: "a\nb\n\n", bracketedPaste: true)), "\u{05}\u{15}\u{1B}[200~a\nb\u{1B}[201~\r")
    }

    func testPlainPathTurnsLineBreaksIntoEnter() {
        XCTAssertEqual(text(InputSender.bytes(text: "echo a\necho b\n", bracketedPaste: false)), "\u{05}\u{15}echo a\recho b\r")
        XCTAssertFalse(InputSender.bytes(text: "a\nb", bracketedPaste: false).contains(0x0A))
    }

    func testPlainPathSendsATabAsControlVTabAndBracketedPathKeepsIt() {
        XCTAssertEqual(text(InputSender.bytes(text: "a\tb", bracketedPaste: false)), "\u{05}\u{15}a\u{16}\tb\r")
        XCTAssertEqual(text(InputSender.bytes(text: "a\tb", bracketedPaste: true)), "\u{05}\u{15}\u{1B}[200~a\tb\u{1B}[201~\r")
    }

    func testAnEmptyLineIsJustEnter() {
        XCTAssertEqual(text(InputSender.bytes(text: "", bracketedPaste: true)), "\u{05}\u{15}\u{1B}[200~\u{1B}[201~\r")
    }

    func testUnicodeGoesAsUTF8() {
        XCTAssertEqual(InputSender.bytes(text: "ação", bracketedPaste: false).suffix(7), Array("ação\r".utf8)[...])
    }
}
