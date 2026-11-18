import XCTest
@testable import WispCore

final class AppIdentityTests: XCTestCase {
    func testIdentityIsGeneric() {
        XCTAssertEqual(AppIdentity.bundleID, "ai.wisp.app")
        XCTAssertEqual(AppIdentity.botLabel, "ai.wisp.bot")
        XCTAssertEqual(AppIdentity.spotifyKeychainService, "ai.wisp.app.spotify")
    }

    func testLegacyIdentityFollowsTheLogin() {
        XCTAssertEqual(AppIdentity.legacyBundleID(login: "Rita"), "com.rita.wisp")
        XCTAssertEqual(AppIdentity.legacySpotifyKeychainService(login: "rita"), "com.rita.wisp.spotify")
    }

    func testDefaultsCopiedOnlyIntoAnEmptyNewDomain() {
        XCTAssertTrue(AppIdentity.shouldCopyDefaults(old: ["k": 1], new: nil))
        XCTAssertTrue(AppIdentity.shouldCopyDefaults(old: ["k": 1], new: [:]))
        XCTAssertFalse(AppIdentity.shouldCopyDefaults(old: ["k": 1], new: ["mine": 2]))
        XCTAssertFalse(AppIdentity.shouldCopyDefaults(old: nil, new: nil))
        XCTAssertFalse(AppIdentity.shouldCopyDefaults(old: [:], new: nil))
    }

    func testKeychainCopiedOnlyWhenTheNewItemIsMissing() {
        XCTAssertTrue(AppIdentity.shouldCopyKeychainItem(oldExists: true, newExists: false))
        XCTAssertFalse(AppIdentity.shouldCopyKeychainItem(oldExists: true, newExists: true))
        XCTAssertFalse(AppIdentity.shouldCopyKeychainItem(oldExists: false, newExists: false))
    }
}
