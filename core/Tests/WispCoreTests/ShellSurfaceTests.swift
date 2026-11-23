import XCTest
@testable import WispCore

final class ShellSurfaceTests: XCTestCase {
    func testPillClickOpensPanelWithoutWindow() {
        XCTAssertEqual(ShellSurface.pillClick(panelOpen: false, windowOpen: false), .openPanel)
        XCTAssertEqual(ShellSurface.pillClick(panelOpen: true, windowOpen: false), .focusPanel)
    }

    func testPillClickFocusesWindowWhenOpen() {
        XCTAssertEqual(ShellSurface.pillClick(panelOpen: false, windowOpen: true), .focusWindow)
        XCTAssertEqual(ShellSurface.pillClick(panelOpen: true, windowOpen: true), .focusWindow)
    }

    func testToggleNeverOpensPanelOverWindow() {
        XCTAssertEqual(ShellSurface.toggle(panelOpen: false, windowOpen: false), .openPanel)
        XCTAssertEqual(ShellSurface.toggle(panelOpen: true, windowOpen: false), .closePanel)
        XCTAssertEqual(ShellSurface.toggle(panelOpen: false, windowOpen: true), .focusWindow)
    }

    func testHoverOpensOnlyWithoutWindow() {
        XCTAssertTrue(ShellSurface.allowsHoverOpen(windowOpen: false))
        XCTAssertFalse(ShellSurface.allowsHoverOpen(windowOpen: true))
    }

    func testActivationFollowsWindow() {
        XCTAssertEqual(ShellSurface.activation(windowOpen: true), .regular)
        XCTAssertEqual(ShellSurface.activation(windowOpen: false), .accessory)
    }

    func testQuitKeepsWindowModeAndUserCloseClearsIt() {
        XCTAssertTrue(ShellSurface.windowModeAfterClose(current: true, quitting: true))
        XCTAssertFalse(ShellSurface.windowModeAfterClose(current: true, quitting: false))
        XCTAssertFalse(ShellSurface.windowModeAfterClose(current: false, quitting: true))
    }

    func testWindowModeDecodesTolerantAndRoundTrips() throws {
        XCTAssertFalse(try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8)).windowMode)
        XCTAssertFalse(try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime","windowMode":"yes"}"#.utf8)).windowMode)
        var settings = WispSettings.default
        settings.windowMode = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(WispSettings.self, from: data).windowMode)
    }
}
