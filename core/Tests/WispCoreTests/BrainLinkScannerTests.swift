import XCTest
@testable import WispCore

final class BrainLinkScannerTests: XCTestCase {
    func testParsesNameHeadingAliasAndEmbed() {
        let found = BrainLinkScanner.scan("a [[Note#Part|shown]] b ![[pic.png|200]] c [[#Self]] [[ spaced ]]")
        XCTAssertEqual(found.map(\.name), ["Note", "pic.png", "", "spaced"])
        XCTAssertEqual(found[0].heading, "Part")
        XCTAssertEqual(found[0].alias, "shown")
        XCTAssertTrue(found[1].isEmbed)
        XCTAssertTrue(found[1].isAttachment)
        XCTAssertEqual(found[2].heading, "Self")
    }

    func testIgnoresCodeFencesInlineCodeAndBlockReferences() {
        let text = "```\n[[fenced]]\n```\n`[[inline]]` [[real]] [[#^block]]\n~~~\n[[tilde]]\n~~~\n[[after]]"
        XCTAssertEqual(BrainLinkScanner.scan(text).map(\.name), ["real", "after"])
    }

    func testFrontmatterIsSkippedUnlessAsked() {
        let text = "---\nrelated: \"[[one]]\"\n---\n[[two]]"
        XCTAssertEqual(BrainLinkScanner.scan(text).map(\.name), ["two"])
        XCTAssertEqual(BrainLinkScanner.scan(text, includeFrontmatter: true).map(\.name), ["one", "two"])
    }

    func testEscapedPipeInsideATableCell() {
        let found = BrainLinkScanner.scan("| [[note\\|alias]] |")
        XCTAssertEqual(found.first?.name, "note")
        XCTAssertEqual(found.first?.alias, "alias")
    }

    func testReportsTheLineOfEachLink() {
        let found = BrainLinkScanner.scan("zero\n[[one]]\n\n[[three]]")
        XCTAssertEqual(found.map(\.line), [1, 3])
    }
}
