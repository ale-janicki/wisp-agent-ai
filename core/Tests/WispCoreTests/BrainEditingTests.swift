import XCTest
@testable import WispCore

final class BrainEditingTests: XCTestCase {
    func testToggleFlipsOnlyTheNamedTaskLine() {
        let text = "- [ ] a\n- [x] b\n  - [X] c\n> - [ ] d\ntext [ ] e\n"
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 0), "- [x] a\n- [x] b\n  - [X] c\n> - [ ] d\ntext [ ] e\n")
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 1), "- [ ] a\n- [ ] b\n  - [X] c\n> - [ ] d\ntext [ ] e\n")
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 2), "- [ ] a\n- [x] b\n  - [ ] c\n> - [ ] d\ntext [ ] e\n")
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 3), "- [ ] a\n- [x] b\n  - [X] c\n> - [x] d\ntext [ ] e\n")
        XCTAssertNil(BrainTasks.toggle(in: text, line: 4))
        XCTAssertNil(BrainTasks.toggle(in: text, line: 99))
    }

    func testToggleThroughTheRenderModelLine() throws {
        let text = "---\nk: v\n---\n# T\n\n- [ ] first\n- [ ] second\n"
        let model = BrainMarkdown.parse(text)
        guard case .list(_, _, let items) = model.nodes[1].block else { return XCTFail("no list") }
        XCTAssertEqual(BrainTasks.toggle(in: text, line: items[1].line), "---\nk: v\n---\n# T\n\n- [ ] first\n- [x] second\n")
    }

    func testReloadSilentlyWhenThereAreNoLocalEdits() {
        XCTAssertEqual(BrainMerge.merge(base: "a\nb", mine: "a\nb", theirs: "a\nb\nc"), .reload("a\nb\nc"))
        XCTAssertEqual(BrainMerge.merge(base: "a", mine: "a", theirs: "a"), .unchanged)
    }

    func testDiskUnchangedKeepsMyEdits() {
        XCTAssertEqual(BrainMerge.merge(base: "a\nb", mine: "a\nB", theirs: "a\nb"), .unchanged)
    }

    func testNonOverlappingEditsMergeCleanly() {
        let base = "one\ntwo\nthree\nfour\nfive"
        let mine = "ONE\ntwo\nthree\nfour\nfive"
        let theirs = "one\ntwo\nthree\nfour\nFIVE\nsix"
        XCTAssertEqual(BrainMerge.merge(base: base, mine: mine, theirs: theirs), .merged("ONE\ntwo\nthree\nfour\nFIVE\nsix"))
    }

    func testBothSidesMakingTheSameEditIsNotAConflict() {
        XCTAssertEqual(BrainMerge.merge(base: "a\nb\nc", mine: "a\nX\nc\nd", theirs: "a\nX\nc"), .merged("a\nX\nc\nd"))
    }

    func testOverlappingEditsKeepBothTextsBetweenMarkers() {
        let outcome = BrainMerge.merge(base: "a\nb\nc", mine: "a\nmine\nc", theirs: "a\ntheirs\nc")
        XCTAssertEqual(outcome, .conflict("a\n<<<<<<< minhas edições\nmine\n=======\ntheirs\n>>>>>>> no disco\nc"))
    }

    func testMergeNeverDropsAnyLineOfEitherSide() {
        let base = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        var mine = base.split(separator: "\n").map(String.init)
        var theirs = mine
        mine[5] = "mine 5"
        mine.insert("added by me", at: 20)
        theirs[30] = "theirs 30"
        theirs.remove(at: 10)
        guard case .merged(let text) = BrainMerge.merge(base: base, mine: mine.joined(separator: "\n"), theirs: theirs.joined(separator: "\n")) else {
            return XCTFail("expected a clean merge")
        }
        XCTAssertTrue(text.contains("mine 5") && text.contains("added by me") && text.contains("theirs 30"))
        XCTAssertFalse(text.contains("line 10"))
    }

    func testRecoveryWritesATimestampedCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try XCTUnwrap(BrainRecovery.save("kept", named: "a/b.md", in: folder, now: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-a__b.md"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "kept")
    }
}

final class BrainSyntaxTests: XCTestCase {
    private func kinds(_ text: String, at needle: String) -> [BrainSyntaxSpan.Kind] {
        let location = (text as NSString).range(of: needle).location
        return BrainSyntax.spans(in: text).filter { NSLocationInRange(location, $0.range) }.map(\.kind)
    }

    func testHighlightsMarkdownConstructs() {
        let text = "# Title\n\n**bold** and *it* and ==mark== and [[Link|x]] and #tag and `code`\n\n> quote\n\n- [ ] task\n"
        XCTAssertTrue(kinds(text, at: "Title").contains(.heading(1)))
        XCTAssertTrue(kinds(text, at: "bold").contains(.bold))
        XCTAssertTrue(kinds(text, at: "it*").contains(.italic))
        XCTAssertTrue(kinds(text, at: "mark").contains(.highlight))
        XCTAssertTrue(kinds(text, at: "[[Link").contains(.wikilink))
        XCTAssertTrue(kinds(text, at: "#tag").contains(.tag))
        XCTAssertTrue(kinds(text, at: "code").contains(.code))
        XCTAssertTrue(kinds(text, at: "quote").contains(.quote))
        XCTAssertTrue(kinds(text, at: "- [ ]").contains(.marker))
    }

    func testFencesAndFrontmatterSuppressInlineStyles() {
        let text = "---\ntags: [a]\n---\n```\n**not bold** [[nope]]\n```\n**yes**\n"
        XCTAssertFalse(kinds(text, at: "not bold").contains(.bold))
        XCTAssertFalse(kinds(text, at: "[[nope").contains(.wikilink))
        XCTAssertTrue(kinds(text, at: "not bold").contains(.codeBlock))
        XCTAssertTrue(kinds(text, at: "tags").contains(.frontmatter))
        XCTAssertTrue(kinds(text, at: "yes").contains(.bold))
    }

    func testAskContextCarriesThePathAndClipsLongNotes() {
        let short = BrainAsk.context(path: "a/b.md", title: "B", text: "hello")
        XCTAssertTrue(short.contains("[[a/b]]") && short.contains("hello") && short.contains("caminho=\"a/b.md\""))
        let long = BrainAsk.context(path: "a/b.md", title: "B", text: String(repeating: "x", count: BrainAsk.limit + 10))
        XCTAssertTrue(long.contains("brain_read"))
        XCTAssertLessThan(long.count, BrainAsk.limit + 400)
    }
}
