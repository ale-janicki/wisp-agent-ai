import Foundation
import Testing

@testable import WispCore

@Suite struct SetupFlowTests {
    @Test func telegramConfiguredOnlyWhenTheDoctorNamesTheJob() {
        let none = DoctorReport(version: 1, checks: [DoctorCheck(id: "telegram", ok: true, summary: "", step: "telegram")])
        #expect(!SetupFlow.telegramConfigured(doctor: none))
        let stopped = DoctorReport(version: 1, checks: [DoctorCheck(id: "telegram", ok: false, summary: "", step: "telegram", data: ["job": "stopped"])])
        #expect(SetupFlow.telegramConfigured(doctor: stopped))
    }

    @Test func existingInstallSeedsFinishedAt() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(SetupFlow.persisted(nil, existingInstall: true, now: now).finishedAt == now)
        let kept = SetupState(finishedAt: Date(timeIntervalSince1970: 5))
        #expect(SetupFlow.persisted(kept, existingInstall: true, now: now).finishedAt == kept.finishedAt)
    }

    @Test func newUserStaysUnfinished() {
        let state = SetupFlow.persisted(SetupState(completed: ["brain"]), existingInstall: false, now: Date())
        #expect(state.finishedAt == nil)
        #expect(SetupGate.shouldShowWizard(state: state, profileExists: true))
    }
}
