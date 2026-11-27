import XCTest

@testable import Wisp

final class HomeDashboardSlotsTests: XCTestCase {
    private func slots(_ heights: [CGFloat]) -> [CGRect] {
        HomeDashboard.slots(heights: heights, width: 410, gap: 10)
    }

    func testEmptyHasNoSlots() {
        XCTAssertTrue(slots([]).isEmpty)
    }

    func testTwoTilesShareARowAndTakeTheTallest() {
        let result = slots([80, 120])
        XCTAssertEqual(result[0], CGRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertEqual(result[1], CGRect(x: 210, y: 0, width: 200, height: 120))
    }

    func testThreeTilesLastSpansTheFullWidthUnderTheRow() {
        let result = slots([80, 120, 60])
        XCTAssertEqual(result[2], CGRect(x: 0, y: 130, width: 410, height: 60))
    }

    func testFourTilesStackRowsByTheirOwnTallest() {
        let result = slots([80, 120, 50, 40])
        XCTAssertEqual(result[2], CGRect(x: 0, y: 130, width: 200, height: 50))
        XCTAssertEqual(result[3], CGRect(x: 210, y: 130, width: 200, height: 50))
    }
}
