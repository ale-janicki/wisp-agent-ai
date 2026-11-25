import XCTest
@testable import WispCore

final class BlockTrackerSelectionTests: XCTestCase {
    private func tracker(commands: Int) -> BlockTracker {
        var tracker = BlockTracker()
        for index in 0..<commands {
            let row = index * 4 + 1
            tracker.apply(.promptStart, anchor: BlockAnchor(row: row, column: 0))
            tracker.apply(.command("c\(index)"), anchor: nil)
            tracker.apply(.commandStart, anchor: BlockAnchor(row: row + 1, column: 0))
            tracker.apply(.commandEnd(exitCode: 0), anchor: BlockAnchor(row: row + 2, column: 0))
        }
        return tracker
    }

    func testIndexNavigationDoesNotLookAtRows() {
        let tracker = tracker(commands: 3)
        let ids = tracker.blocks.map(\.id)
        XCTAssertEqual(tracker.index(of: ids[1]), 1)
        XCTAssertNil(tracker.index(of: 999))
        XCTAssertEqual(tracker.previousID(before: ids[2]), ids[1])
        XCTAssertNil(tracker.previousID(before: ids[0]), "nothing above the first block")
        XCTAssertEqual(tracker.previousID(before: nil), ids[2], "nothing selected: ⌘↑ lands on the last block")
        XCTAssertEqual(tracker.previousID(before: 999), ids[2], "a block that left the list counts as no selection")
        XCTAssertEqual(tracker.nextID(after: ids[0]), ids[1])
        XCTAssertNil(tracker.nextID(after: ids[2]))
        XCTAssertNil(tracker.nextID(after: nil))
    }

    func testPlainMovesPickOneBlockAndStopAtTheEnds() {
        let order = [10, 11, 12]
        var selection = BlockSelection()
        XCTAssertNil(selection.move(1, extend: false, in: order), "⌘↓ with nothing selected does nothing")
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.move(-1, extend: false, in: order), 12)
        XCTAssertEqual(selection.move(-1, extend: false, in: order), 11)
        XCTAssertEqual(selection.ids, [11])
        XCTAssertEqual(selection.move(-1, extend: false, in: order), 10)
        XCTAssertEqual(selection.move(-1, extend: false, in: order), 10, "stays at the first block")
        XCTAssertEqual(selection.move(1, extend: false, in: order), 11)
        XCTAssertEqual(selection.ids, [11])
    }

    func testExtendingKeepsTheAnchorAndShrinksBack() {
        let order = [1, 2, 3, 4, 5]
        var selection = BlockSelection()
        selection.select(3)
        selection.move(-1, extend: true, in: order)
        selection.move(-1, extend: true, in: order)
        XCTAssertEqual(selection.ordered(in: order), [1, 2, 3])
        selection.move(1, extend: true, in: order)
        XCTAssertEqual(selection.ordered(in: order), [2, 3], "moving back toward the anchor gives blocks up")
        for _ in 0..<3 { selection.move(1, extend: true, in: order) }
        XCTAssertEqual(selection.ordered(in: order), [3, 4, 5], "past the anchor the range flips to the other side")
    }

    func testCommandClickTogglesAndShiftClickTakesARange() {
        let order = [1, 2, 3, 4, 5, 6]
        var selection = BlockSelection()
        selection.select(2)
        selection.toggle(5)
        XCTAssertEqual(selection.ordered(in: order), [2, 5])
        selection.selectRange(to: 3, in: order)
        XCTAssertEqual(selection.ordered(in: order), [3, 4, 5], "the range runs from the last click (5) to 3")
        selection.toggle(4)
        XCTAssertEqual(selection.ordered(in: order), [3, 5])
        var fresh = BlockSelection()
        fresh.selectRange(to: 4, in: order)
        XCTAssertEqual(fresh.ids, [4], "no anchor: a plain click")
    }

    func testPruneDropsBlocksThatLeftAndClearsWhenNoneIsLeft() {
        var selection = BlockSelection()
        selection.select(1)
        selection.toggle(2)
        selection.prune(to: [2, 3])
        XCTAssertEqual(selection.ids, [2])
        selection.prune(to: [3])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.cursor)
        XCTAssertNil(selection.anchor)
    }

    func testSearchFindsCommandsAndOutputsInListOrder() {
        let blocks = [
            (id: 1, command: "echo Hello", output: "hello\nworld hello"),
            (id: 2, command: "ls", output: "résumé"),
        ]
        let found = BlockSearch.matches(for: "hello", in: blocks)
        XCTAssertEqual(found.map(\.blockID), [1, 1, 1])
        XCTAssertEqual(found.map(\.field), [.command, .output, .output])
        XCTAssertEqual(found[0].range, 5..<10)
        XCTAssertEqual(found[2].range, 12..<17)
        XCTAssertEqual(BlockSearch.matches(for: "resume", in: blocks).map(\.blockID), [2], "accents do not matter")
        XCTAssertTrue(BlockSearch.matches(for: "", in: blocks).isEmpty)
        XCTAssertTrue(BlockSearch.matches(for: "zzz", in: blocks).isEmpty)
    }
}
