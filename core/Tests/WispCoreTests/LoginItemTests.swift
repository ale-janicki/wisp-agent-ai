import XCTest
@testable import WispCore

final class LoginItemTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/ana", isDirectory: true)

    private func installed(_ path: String) -> Bool {
        LoginItemPolicy.isInstalled(bundle: URL(fileURLWithPath: path, isDirectory: true), home: home)
    }

    func testOnlyAnAppInApplicationsCountsAsInstalled() {
        XCTAssertTrue(installed("/Applications/Wisp.app"))
        XCTAssertTrue(installed("/Applications/Utilities/Wisp.app"))
        XCTAssertTrue(installed("/Users/ana/Applications/Wisp.app"))
        XCTAssertFalse(installed("/Users/ana/Library/Developer/Xcode/DerivedData/Wisp-x/Build/Products/Debug/Wisp.app"))
        XCTAssertFalse(installed("/Users/ana/Downloads/Wisp.app"))
        XCTAssertFalse(installed("/ApplicationsOld/Wisp.app"))
        XCTAssertFalse(installed("/Applications/../tmp/Wisp.app"))
        XCTAssertFalse(installed("/Users/bob/Applications/Wisp.app"))
    }

    func testRegistersOnceWhenWantedFinishedInstalledAndNotThere() {
        for status in [LoginItemStatus.notRegistered, .notFound] {
            XCTAssertEqual(LoginItemPolicy.action(wanted: true, setupFinished: true, installed: true, status: status, registeredBefore: false), .register)
        }
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            XCTAssertEqual(LoginItemPolicy.action(wanted: true, setupFinished: true, installed: true, status: status, registeredBefore: false), .nothing)
        }
        XCTAssertEqual(LoginItemPolicy.action(wanted: true, setupFinished: false, installed: true, status: .notRegistered, registeredBefore: false), .nothing)
    }

    func testARemovalInSystemSettingsIsRespected() {
        for status in [LoginItemStatus.notRegistered, .notFound] {
            XCTAssertEqual(LoginItemPolicy.action(wanted: true, setupFinished: true, installed: true, status: status, registeredBefore: true), .nothing)
        }
        XCTAssertTrue(LoginItemPolicy.removedByUser(wanted: true, status: .notRegistered, registeredBefore: true))
        XCTAssertFalse(LoginItemPolicy.removedByUser(wanted: true, status: .enabled, registeredBefore: true))
        XCTAssertFalse(LoginItemPolicy.removedByUser(wanted: true, status: .notRegistered, registeredBefore: false))
        XCTAssertFalse(LoginItemPolicy.removedByUser(wanted: false, status: .notRegistered, registeredBefore: true))
    }

    func testTheSwitchShowsWhatMacOSHas() {
        XCTAssertTrue(LoginItemPolicy.isOn(.enabled))
        XCTAssertTrue(LoginItemPolicy.isOn(.requiresApproval))
        XCTAssertFalse(LoginItemPolicy.isOn(.notRegistered))
        XCTAssertFalse(LoginItemPolicy.isOn(.notFound))
    }

    func testUnregistersWhenSwitchedOffAndStillThere() {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            for before in [true, false] {
                XCTAssertEqual(LoginItemPolicy.action(wanted: false, setupFinished: true, installed: true, status: status, registeredBefore: before), .unregister)
            }
        }
        for status in [LoginItemStatus.notRegistered, .notFound] {
            XCTAssertEqual(LoginItemPolicy.action(wanted: false, setupFinished: true, installed: true, status: status, registeredBefore: true), .nothing)
        }
    }

    func testABuildOutsideApplicationsNeverTouchesTheLoginItem() {
        for wanted in [true, false] {
            for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
                XCTAssertEqual(LoginItemPolicy.action(wanted: wanted, setupFinished: true, installed: false, status: status, registeredBefore: false), .nothing)
            }
        }
    }

    func testSettingDefaultsOnAndOldFilesLoadOn() throws {
        XCTAssertTrue(WispSettings.default.openAtLogin)
        let saved = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertTrue(saved.openAtLogin)
        var off = WispSettings.default
        off.openAtLogin = false
        XCTAssertFalse(try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(off)).openAtLogin)
        XCTAssertFalse(saved.loginItemRegistered)
        var registered = WispSettings.default
        registered.loginItemRegistered = true
        XCTAssertTrue(try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(registered)).loginItemRegistered)
    }
}
