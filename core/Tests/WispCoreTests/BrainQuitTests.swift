import XCTest
@testable import WispCore

@MainActor
final class BrainQuitTests: XCTestCase {
    func testTheQuitFlushIsNotEmptyWhileANoteIsOpenAndFlushAllRunsTheBrainFlusher() async throws {
        let vault = try BrainVaultFixture()
        let files = BrainFiles(root: vault.path)
        let quit = QuitFlush()
        var unsaved: String? = "typed 300 ms ago"
        let registration = BrainQuitRegistration(quit: quit) { try? files.write(unsaved ?? "", to: "index.md"); unsaved = nil }
        XCTAssertTrue(quit.isEmpty)
        registration.update(hasOpenNotes: true)
        registration.update(hasOpenNotes: true)
        XCTAssertFalse(quit.isEmpty)
        await quit.flushAll(timeout: .seconds(2))
        XCTAssertEqual(try vault.text("index.md"), "typed 300 ms ago")
        registration.update(hasOpenNotes: false)
        XCTAssertTrue(quit.isEmpty)
        XCTAssertFalse(registration.isRegistered)
    }

    func testTheSecondFlushOfTheSameTextDoesNotWriteAgain() {
        var ledger = BrainRecoveryLedger()
        XCTAssertTrue(ledger.shouldCopy("a.md", text: "v1"))
        XCTAssertFalse(ledger.shouldCopy("a.md", text: "v1"))
        XCTAssertTrue(ledger.shouldCopy("a.md", text: "v2"))
        ledger.forget("a.md")
        XCTAssertTrue(ledger.shouldCopy("a.md", text: "v2"))
    }

    func testTheSigtermFallbackOutlastsTheFlushAndTheWillTerminateMargin() {
        XCTAssertGreaterThan(QuitDeadline.sigtermFallbackSeconds, QuitDeadline.flushSeconds + QuitDeadline.willTerminateMarginSeconds - 0.001)
        XCTAssertEqual(QuitDeadline.flushTimeout, .seconds(3))
    }

    func testAFlusherThatNeverReturnsIsCutAtTheTimeoutNotTheFallback() async {
        let quit = QuitFlush()
        let registration = BrainQuitRegistration(quit: quit) {}
        registration.update(hasOpenNotes: true)
        let stuck = quit.register { try? await Task.sleep(for: .seconds(30)) }
        let start = Date()
        await quit.flushAll(timeout: .milliseconds(300))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        quit.unregister(stuck)
    }
}
