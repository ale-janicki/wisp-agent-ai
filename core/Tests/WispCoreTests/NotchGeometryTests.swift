import XCTest
import CoreGraphics
@testable import WispCore

final class NotchGeometryTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1280, height: 832)
    private let notch = CGRect(x: 1280 / 2 - 92, y: 832 - 32, width: 184, height: 32)
    private let ultrawide = CGRect(x: 0, y: 0, width: 2560, height: 1080)

    func testRestHasWingsAroundNotch() {
        let f = NotchGeometry.frame(for: .rest, screen: builtIn, notch: notch)
        XCTAssertEqual(f.width, notch.width + 72)
        XCTAssertEqual(f.height, notch.height)
        XCTAssertEqual(f.midX, notch.midX)
        XCTAssertEqual(f.maxY, notch.maxY)
    }

    private let macBook = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    private let macBookNotch = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)

    func testRestOnRealNotchIsCenteredOnCamera() {
        let f = NotchGeometry.frame(for: .rest, screen: macBook, notch: macBookNotch)
        XCTAssertEqual(f, CGRect(x: 715, y: 1074.5, width: 280, height: 37.5))
        XCTAssertEqual(f.midX, 855)
    }

    func testActiveKeepsRestBandAndDropsDown() {
        for (screen, candidate) in [(macBook, Optional(macBookNotch)), (builtIn, Optional(notch)), (ultrawide, nil)] {
            let rest = NotchGeometry.frame(for: .rest, screen: screen, notch: candidate)
            let band = NotchGeometry.topBand(screen: screen, notch: candidate)
            let active = NotchGeometry.frame(for: .active, screen: screen, notch: candidate)
            XCTAssertEqual(band, rest)
            XCTAssertEqual(active.midX, band.midX)
            XCTAssertEqual(active.maxY, band.maxY)
            XCTAssertEqual(active.width, 420)
            XCTAssertEqual(active.height, band.height + NotchGeometry.stripHeight)
            XCTAssertTrue(active.contains(band))
        }
        let active = NotchGeometry.frame(for: .active, screen: macBook, notch: macBookNotch)
        XCTAssertEqual(active.midX, 855)
    }

    func testNoNotchBandIs200x32Centered() {
        let band = NotchGeometry.topBand(screen: ultrawide, notch: nil)
        XCTAssertEqual(band, CGRect(x: 1180, y: 1048, width: 200, height: 32))
    }

    func testPanelCenteredOnNotch() {
        let f = NotchGeometry.frame(for: .panel, screen: builtIn, notch: notch)
        XCTAssertEqual(f.size, CGSize(width: 860, height: 540))
        XCTAssertEqual(f.maxY, builtIn.maxY)
        XCTAssertEqual(f.midX, notch.midX)
    }

    func testNoNotchFallback() {
        let f = NotchGeometry.frame(for: .rest, screen: ultrawide, notch: nil)
        XCTAssertEqual(f.size, CGSize(width: 200, height: 32))
        XCTAssertEqual(f.maxY, ultrawide.maxY)
        XCTAssertEqual(f.midX, ultrawide.midX)
        let p = NotchGeometry.frame(for: .panel, screen: ultrawide, notch: nil)
        XCTAssertEqual(p.midX, ultrawide.midX)
        XCTAssertEqual(p.maxY, ultrawide.maxY)
    }

    func testPanelNeverExceedsScreen() {
        let narrow = CGRect(x: 100, y: 0, width: 600, height: 400)
        let f = NotchGeometry.frame(for: .panel, screen: narrow, notch: nil)
        XCTAssertTrue(narrow.contains(f))
        XCTAssertEqual(f.width, 600)
        XCTAssertEqual(f.height, 400)

        let rightNotch = CGRect(x: 1180, y: 832 - 32, width: 100, height: 32)
        let g = NotchGeometry.frame(for: .panel, screen: builtIn, notch: rightNotch)
        XCTAssertEqual(g.width, 860)
        XCTAssertEqual(g.maxX, builtIn.maxX)
        XCTAssertEqual(g.minX, g.maxX - 860)

        let leftNotch = CGRect(x: 0, y: 832 - 32, width: 100, height: 32)
        let h = NotchGeometry.frame(for: .panel, screen: builtIn, notch: leftNotch)
        XCTAssertEqual(h.minX, builtIn.minX)
        XCTAssertEqual(h.width, 860)
    }

    func testNonZeroOriginScreens() {
        let screens = [
            CGRect(x: 1280, y: 0, width: 1280, height: 832),
            CGRect(x: -2560, y: 0, width: 2560, height: 1080),
            CGRect(x: 0, y: -200, width: 1280, height: 832),
        ]
        for screen in screens {
            let notch = CGRect(x: screen.midX - 92, y: screen.maxY - 32, width: 184, height: 32)
            for candidate in [Optional(notch), nil] {
                let centerX = candidate?.midX ?? screen.midX
                for state in [PillState.rest, .active, .panel] {
                    let f = NotchGeometry.frame(for: state, screen: screen, notch: candidate)
                    XCTAssertEqual(f.midX, centerX, "\(state) \(screen)")
                    XCTAssertEqual(f.maxY, screen.maxY, "\(state) \(screen)")
                }
                let active = NotchGeometry.frame(for: .active, screen: screen, notch: candidate)
                XCTAssertEqual(active.width, 420)
                XCTAssertEqual(active.height, (candidate?.height ?? 32) + NotchGeometry.stripHeight)
            }
        }
    }
}
