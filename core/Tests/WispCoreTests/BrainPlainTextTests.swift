import XCTest
@testable import WispCore

final class BrainPlainTextTests: XCTestCase {
    func testAListLineWithWikilinkBoldAndCodeReadsAsPlainText() {
        XCTAssertEqual(BrainPlainText.preview("- [[moonxi-index]] — **`moonxi/`** pasta"), "moonxi-index — moonxi/ pasta")
    }

    func testAnAliasedWikilinkShowsItsAlias() {
        XCTAssertEqual(BrainPlainText.preview("ver [[a|Nome B]] e [[c]]"), "ver Nome B e c")
    }

    func testATableRowBecomesDotSeparatedCellsWithoutEmptyOnes() {
        XCTAssertEqual(BrainPlainText.preview("| [[x]] | `y` | 280 | |"), "x · y · 280")
    }

    func testAQuoteAndHeadingLoseTheirMarkers() {
        XCTAssertEqual(BrainPlainText.preview("> 🔑 **Desenho** final"), "🔑 Desenho final")
        XCTAssertEqual(BrainPlainText.preview("## Título   aqui"), "Título aqui")
    }

    func testMarkdownLinksKeepTheirTextAndSnakeCaseSurvives() {
        XCTAssertEqual(BrainPlainText.preview("veja [docs](https://x.io/a) e _forte_ em snake_case"), "veja docs e forte em snake_case")
    }
}
