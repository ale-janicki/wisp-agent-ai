import XCTest
@testable import WispCore

final class BrainMarkdownTests: XCTestCase {
    private func blocks(_ text: String) -> [BrainBlock] { BrainMarkdown.parse(text).nodes.map(\.block) }

    private func inlines(_ text: String) -> [BrainInline] {
        guard case .paragraph(let inline)? = blocks(text).first else { return [] }
        return inline
    }

    func testHeadingsOutlineAndLinesIgnoreFrontmatter() {
        let model = BrainMarkdown.parse("---\na: 1\n---\n# One\n\ntext\n\n## Two ##\n\n```\n# not a heading\n```\n")
        XCTAssertEqual(model.headings.map(\.text), ["One", "Two"])
        XCTAssertEqual(model.headings.map(\.line), [3, 7])
        XCTAssertEqual(model.headingLine(matching: "two"), 7)
        XCTAssertEqual(model.headingLine(matching: "note#Two"), 7)
    }

    func testInlineStylesHighlightsAndTags() {
        XCTAssertEqual(inlines("a **b** *c* ~~d~~ ==e== `f` #g"), [
            .text("a "), .bold([.text("b")]), .text(" "), .italic([.text("c")]), .text(" "), .strike([.text("d")]), .text(" "),
            .highlight([.text("e")]), .text(" "), .code("f"), .text(" "), .tag("g"),
        ])
        XCTAssertEqual(inlines("snake_case_name and 2*3*4"), [.text("snake_case_name and 2"), .italic([.text("3")]), .text("4")])
        XCTAssertEqual(inlines("***both***"), [.bold([.italic([.text("both")])])])
        XCTAssertEqual(inlines("not a #123 tag, but a#b neither"), [.text("not a #123 tag, but a#b neither")])
    }

    func testWikilinksEmbedsAndExternalLinks() {
        XCTAssertEqual(inlines("see [[Note#Part|label]] and [x](https://a.example/p?q=1) and https://b.example/z."), [
            .text("see "), .wikilink(BrainWikiLink(name: "Note", heading: "Part", alias: "label")), .text(" and "),
            .link(label: [.text("x")], url: "https://a.example/p?q=1"), .text(" and "),
            .link(label: [.text("https://b.example/z")], url: "https://b.example/z"), .text("."),
        ])
        XCTAssertEqual(BrainWikiLink(name: "Note", heading: "Part").display, "Note > Part")
        XCTAssertEqual(BrainWikiLink(name: "", heading: "Part").display, "Part")
    }

    func testEmbedsBecomeBlocksOrInlineAndPickTheirKind() {
        XCTAssertEqual(blocks("![[pic.png|200]]"), [.embed(BrainEmbed(name: "pic.png", option: "200"))])
        XCTAssertEqual(BrainEmbed(name: "pic.png").kind, .image)
        XCTAssertEqual(BrainEmbed(name: "Sketch.excalidraw").kind, .drawing)
        XCTAssertEqual(BrainEmbed(name: "Sketch.excalidraw.md").kind, .drawing)
        XCTAssertEqual(BrainEmbed(name: "board.canvas").kind, .drawing)
        XCTAssertEqual(BrainEmbed(name: "Some note", heading: "Part").kind, .note)
        XCTAssertEqual(BrainEmbed(name: "paper.pdf").kind, .attachment)
        XCTAssertEqual(inlines("a ![[x.png]] b").count, 3)
    }

    func testTasksKeepTheirSourceLineAndNestedLists() {
        let model = BrainMarkdown.parse("intro\n\n- [ ] one\n- [x] two\n  - nested item\n  - [ ] sub task\n1. first\n")
        guard case .list(_, _, let items) = model.nodes[1].block else { return XCTFail("no list") }
        XCTAssertEqual(items.map(\.task), [.open, .done])
        XCTAssertEqual(items.map(\.line), [2, 3])
        guard case .list(_, _, let nested) = items[1].blocks.last?.block else { return XCTFail("no nested list") }
        XCTAssertEqual(nested.map(\.task), [nil, .open])
        XCTAssertEqual(nested.last?.line, 5)
        guard case .list(let ordered, _, _) = model.nodes[2].block else { return XCTFail("no ordered list") }
        XCTAssertTrue(ordered)
    }

    func testTablesWithAlignmentAndEscapedPipes() {
        let text = "| Name | Qty |\n|:--|--:|\n| [[a\\|b]] | 3 |\n| `x|y` | 4 |\n"
        guard case .table(let header, let alignments, let rows) = blocks(text)[0] else { return XCTFail("no table") }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(alignments, [.leading, .trailing])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], [.wikilink(BrainWikiLink(name: "a", alias: "b"))])
        XCTAssertEqual(rows[1][0], [.code("x|y")])
    }

    func testCalloutsFoldingAndDefaultTitle() {
        let text = "> [!warning]- Careful\n> first line\n> - item\n\n> [!note]\n> body\n\n> plain quote\n"
        let found = blocks(text)
        guard case .callout(let kind, let title, let foldable, let collapsed, let body) = found[0] else { return XCTFail("no callout") }
        XCTAssertEqual(kind, "warning")
        XCTAssertEqual(title, [.text("Careful")])
        XCTAssertTrue(foldable && collapsed)
        XCTAssertEqual(body.count, 2)
        guard case .callout(_, let defaultTitle, let foldableNote, _, _) = found[1] else { return XCTFail("no second callout") }
        XCTAssertEqual(defaultTitle, [.text("Note")])
        XCTAssertFalse(foldableNote)
        guard case .quote = found[2] else { return XCTFail("no quote") }
    }

    func testCodeBlocksKeepContentAndLanguageUntouched() {
        let text = "```swift\nlet a = [[not a link]]  **raw**\n\n    indented\n```\nafter"
        XCTAssertEqual(blocks(text), [
            .code(language: "swift", text: "let a = [[not a link]]  **raw**\n\n    indented"), .paragraph([.text("after")]),
        ])
    }

    func testFootnotesCollectAtTheEndAndCommentsVanish() {
        let model = BrainMarkdown.parse("Claim[^1] here.\n\n%%hidden\nmore hidden%%\n\n[^1]: The source.\n")
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertEqual(model.nodes[0].block, .paragraph([.text("Claim"), .footnote("1"), .text(" here.")]))
        guard case .footnotes(let notes) = model.nodes[1].block else { return XCTFail("no footnotes") }
        XCTAssertEqual(notes, [BrainFootnote(label: "1", content: [.text("The source.")])])
    }

    func testRulesParagraphsAndSoftBreaks() {
        XCTAssertEqual(blocks("a\nb\n\n---\n\nc"), [.paragraph([.text("a"), .lineBreak, .text("b")]), .rule, .paragraph([.text("c")])])
    }

    func testModelCollectsTagsFromProse() {
        XCTAssertEqual(BrainMarkdown.parse("work #alpha\n\n- item #Beta/sub\n").tags, ["alpha", "beta/sub"])
    }

    func testSectionExtractionStopsAtThePeerHeading() {
        let text = "# A\nintro\n## B\nbody\n### C\ndeep\n## D\nother\n"
        XCTAssertEqual(BrainSections.extract(text, heading: "b"), "## B\nbody\n### C\ndeep")
        XCTAssertEqual(BrainSections.extract(text, heading: "D"), "## D\nother")
        XCTAssertNil(BrainSections.extract(text, heading: "none"))
    }

    func testLargeNoteParsesQuickly() {
        let text = (0..<4000).map { "## Part \($0)\n\nSome **bold** text with [[Link \($0)]] and a #tag.\n\n- [ ] task \($0)\n" }.joined()
        let start = Date()
        let model = BrainMarkdown.parse(text)
        XCTAssertEqual(model.headings.count, 4000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
