import XCTest
@testable import WispCore

final class LineBufferTests: XCTestCase {
    func testLineSplitAcrossTwoAppends() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n".utf8)), ["{\"a\":1}"])
    }

    func testTwoLinesInOneAppend() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("one\ntwo\n".utf8)), ["one", "two"])
    }

    func testTrailingPartialIsKept() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(buffer.append(Data("o\n".utf8)), ["two"])
    }

    func testMultibyteCharacterSplitAcrossAppends() {
        var buffer = LineBuffer()
        let bytes = Array("é\n".utf8)
        XCTAssertEqual(buffer.append(Data(bytes[0..<1])), [])
        XCTAssertEqual(buffer.append(Data(bytes[1...])), ["é"])
    }
}
