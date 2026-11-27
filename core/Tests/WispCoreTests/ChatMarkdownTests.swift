import XCTest
@testable import WispCore

final class ChatMarkdownTests: XCTestCase {
    func testReducerOutputOfAlignedColumnsIsOneCodeBlockWithFiveLines() {
        let raw = TelegramHTML.markdown("O pedido soma <b>R$ 120,00</b>...\n\n<pre>\nItem A                   10,00\nItem B                   30,00\nItem C                   50,00\nItem D                   30,00\nTotal                   120,00\n</pre>\n\nO item A ja foi pago...")
        let segments = ChatMarkdown.segments(raw)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text("O pedido soma **R$ 120,00**..."))
        guard case .code(let code) = segments[1] else { return XCTFail("expected code") }
        let lines = code.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "Item A                   10,00")
        XCTAssertEqual(lines[4], "Total                   120,00")
        XCTAssertEqual(segments[2], .text("O item A ja foi pago..."))
    }

    func testMarkdownFenceKeepsNewlinesAndIgnoresLanguage() {
        XCTAssertEqual(ChatMarkdown.segments("antes\n```swift\nlet a = 1\n\nlet b = 2\n```\ndepois"),
                       [.text("antes"), .code("let a = 1\n\nlet b = 2"), .text("depois")])
    }

    func testUnclosedFenceIsCodeToTheEnd() {
        XCTAssertEqual(ChatMarkdown.segments("oi\n```\na\nb"), [.text("oi"), .code("a\nb")])
        XCTAssertEqual(ChatMarkdown.segments("```"), [.code("")])
    }

    func testTable() {
        let segments = ChatMarkdown.segments("x\n\n| Nome | Valor |\n| --- | ---: |\n| a | 1 |\n| b \\| c | 2 |\n\ny")
        XCTAssertEqual(segments, [.text("x"), .table(header: ["Nome", "Valor"], rows: [["a", "1"], ["b | c", "2"]]), .text("y")])
    }

    func testPipeLineWithoutDelimiterStaysText() {
        XCTAssertEqual(ChatMarkdown.segments("a | b\nc"), [.text("a | b\nc")])
    }

    func testPlainTextIsSingleSegmentAndInlineBacktickIsNotAFence() {
        XCTAssertEqual(ChatMarkdown.segments("use ```x``` aqui\nlinha"), [.text("use ```x``` aqui\nlinha")])
        XCTAssertEqual(ChatMarkdown.segments(""), [])
    }

    func testFenceInsideListItemIsCodeAndClosesCleanly() {
        XCTAssertEqual(ChatMarkdown.segments("passos:\n- ```swift\n  let a = 1\n  ```\ndepois"),
                       [.text("passos:"), .code("  let a = 1"), .text("depois")])
        XCTAssertEqual(ChatMarkdown.segments("1. ```\nx\n```\nfim"), [.code("x"), .text("fim")])
    }

    func testDeeplyIndentedFenceIsNotAnOpenerSoItCannotSwallowTheRest() {
        XCTAssertEqual(ChatMarkdown.segments("- item\n      ```\n  resto"), [.text("- item\n      ```\n  resto")])
    }

    func testFenceOpenerIndentedUpToThreeSpaces() {
        XCTAssertEqual(ChatMarkdown.segments("   ```\nx\n   ```"), [.code("x")])
    }

    func testDelimiterRowNeedsPipeAndMatchingColumns() {
        XCTAssertEqual(ChatMarkdown.segments("a | b\n---"), [.text("a | b\n---")])
        XCTAssertEqual(ChatMarkdown.segments("a | b\n| --- |"), [.text("a | b\n| --- |")])
        XCTAssertEqual(ChatMarkdown.segments("a | b\n--- | ---\nc | d"), [.table(header: ["a", "b"], rows: [["c", "d"]])])
    }

    func testRawTelegramHtmlIsLeftAlone() {
        XCTAssertEqual(ChatMarkdown.segments("<b>x</b> &amp; y"), [.text("<b>x</b> &amp; y")])
    }
}
