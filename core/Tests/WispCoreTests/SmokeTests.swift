import XCTest
@testable import WispCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Wisp.version, "0.1.0")
    }
}
