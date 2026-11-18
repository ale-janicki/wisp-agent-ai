import Foundation
import Testing

@testable import WispCore

@Suite struct SetupFlowTests {
    private func doctor(clt: Bool, claude: Bool) -> DoctorReport {
        DoctorReport(version: 1, checks: [
            DoctorCheck(id: "clt", ok: clt, summary: "", step: "system"),
            DoctorCheck(id: "claude", ok: claude, summary: "", step: "system"),
        ])
    }

    @Test func rerunsSystemWhenOnlyTheToolsAreIn() {
        #expect(SetupFlow.shouldRerunSystem(doctor: doctor(clt: true, claude: false)))
        #expect(SetupFlow.shouldRerunSystem(doctor: doctor(clt: true, claude: true)))
        #expect(!SetupFlow.shouldRerunSystem(doctor: doctor(clt: false, claude: false)))
        #expect(!SetupFlow.shouldRerunSystem(doctor: DoctorReport(version: 1, checks: [])))
    }

    @Test func unreadableDoctorOpensOnSystem() {
        let state = SetupState(completed: ["system", "brain"])
        #expect(SetupFlow.openingStep(doctor: nil, state: state) == .system)
    }

    @Test func readableDoctorOpensOnFirstIncomplete() {
        #expect(SetupFlow.openingStep(doctor: doctor(clt: true, claude: false), state: SetupState()) == .system)
        #expect(SetupFlow.openingStep(doctor: doctor(clt: true, claude: true), state: SetupState()) == .done)
    }

    @Test func existingInstallSeedsFinishedAt() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(SetupFlow.persisted(nil, existingInstall: true, now: now).finishedAt == now)
        let kept = SetupState(finishedAt: Date(timeIntervalSince1970: 5))
        #expect(SetupFlow.persisted(kept, existingInstall: true, now: now).finishedAt == kept.finishedAt)
    }

    @Test func newUserStaysUnfinished() {
        let state = SetupFlow.persisted(SetupState(completed: ["system"]), existingInstall: false, now: Date())
        #expect(state.finishedAt == nil)
        #expect(SetupGate.shouldShowWizard(state: state, profileExists: true))
    }
}
