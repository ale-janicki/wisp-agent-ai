import XCTest
@testable import WispCore

final class SetupGateTests: XCTestCase {
    func testFreshMacShowsWizard() {
        XCTAssertTrue(SetupGate.shouldShowWizard(state: nil, profileExists: false))
    }

    func testExistingProfileWithoutStateIsAdopted() {
        XCTAssertFalse(SetupGate.shouldShowWizard(state: nil, profileExists: true))
    }

    func testFinishedNeverShows() {
        let state = SetupState(completed: [], skipped: [], finishedAt: Date())
        XCTAssertFalse(SetupGate.shouldShowWizard(state: state, profileExists: false))
    }

    func testUnfinishedStateShows() {
        XCTAssertTrue(SetupGate.shouldShowWizard(state: SetupState(), profileExists: true))
    }
}
