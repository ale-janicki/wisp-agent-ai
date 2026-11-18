import XCTest
@testable import WispCore

final class SetupGateTests: XCTestCase {
    private func doctor(_ failing: [(String, String?)]) -> DoctorReport {
        DoctorReport(version: 1, checks: failing.map { DoctorCheck(id: $0.0, ok: false, summary: "", step: $0.1) })
    }

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

    func testFirstIncompleteFollowsDoctorOrder() {
        let report = doctor([("login", "login"), ("brain", "brain")])
        XCTAssertEqual(SetupGate.firstIncomplete(doctor: report, state: SetupState()), .login)
    }

    func testSkippedTelegramIsNotIncomplete() {
        let report = doctor([("telegram", "telegram")])
        XCTAssertEqual(SetupGate.firstIncomplete(doctor: report, state: SetupState(skipped: ["telegram"])), .done)
    }

    func testAllGoodIsDone() {
        XCTAssertEqual(SetupGate.firstIncomplete(doctor: doctor([]), state: SetupState()), .done)
    }
}
