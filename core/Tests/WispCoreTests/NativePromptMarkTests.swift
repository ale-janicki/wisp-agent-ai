import XCTest
@testable import WispCore

final class NativePromptMarkTests: XCTestCase {
    private let nonce = "0123456789abcdef"

    private func events(_ marks: [String]) -> [ShellEvent] {
        var scanner = ShellMarkScanner(nonce: nonce)
        let bytes = marks.map { "\u{1B}]6973;\(nonce);\($0)\u{07}" }.joined()
        return scanner.scan(Array(bytes.utf8)[...]).map(\.event)
    }

    func testASecondBWithoutANewAIsARedraw() {
        XCTAssertEqual(events(["A", "B", "B", "B"]), [.promptStart, .promptEnd])
        XCTAssertEqual(events(["A", "B", "B", "C", "D;0", "A", "B"]), [.promptStart, .promptEnd, .commandStart, .commandEnd(exitCode: 0), .promptStart, .promptEnd])
    }

    func testABWithNoAHasNoPromptToEnd() {
        XCTAssertEqual(events(["B"]), [])
    }

    func testTheRedrawStateSurvivesAReadBoundary() {
        var scanner = ShellMarkScanner(nonce: nonce)
        let a = "\u{1B}]6973;\(nonce);A\u{07}\u{1B}]6973;\(nonce);B\u{07}"
        let b = "\u{1B}]6973;\(nonce);B\u{07}"
        XCTAssertEqual(scanner.scan(Array(a.utf8)[...]).map(\.event), [.promptStart, .promptEnd])
        XCTAssertEqual(scanner.scan(Array(b.utf8)[...]).map(\.event), [])
    }

    func testHistoryFileMarkCarriesTheDecodedPath() {
        let encoded = Data("/Users/x/.zsh_history".utf8).base64EncodedString()
        XCTAssertEqual(events(["hist=\(encoded)"]), [.historyFile("/Users/x/.zsh_history")])
        XCTAssertEqual(events(["hist="]), [])
    }
}
