import XCTest
@testable import WispCore

final class ChatMarkdownTests: XCTestCase {
    func testReducerOutputOfScreenshotIsOneCodeBlockWithFiveLines() {
        let raw = TelegramHTML.markdown("A Rafa ainda te deve <b>R$ 589,75</b>...\n\n<pre>\nNatsuki (resto)          48,43\nPetz (itens dela)       173,66\nAssaí (parte dela)      289,66\nPizzaria Skalone         78,00\nTotal                   589,75\n</pre>\n\nOs R$ 48,43...")
        let segments = ChatMarkdown.segments(raw)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text("A Rafa ainda te deve **R$ 589,75**..."))
        guard case .code(let code) = segments[1] else { return XCTFail("expected code") }
        let lines = code.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "Natsuki (resto)          48,43")
        XCTAssertEqual(lines[4], "Total                   589,75")
        XCTAssertEqual(segments[2], .text("Os R$ 48,43..."))
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
