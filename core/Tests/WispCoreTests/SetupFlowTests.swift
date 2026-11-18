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
        #expect(SetupFlow.shouldRerunSystem(after: .commandLineTools, doctor: doctor(clt: true, claude: false)))
        #expect(SetupFlow.shouldRerunSystem(after: .commandLineTools, doctor: doctor(clt: true, claude: true)))
        #expect(!SetupFlow.shouldRerunSystem(after: .commandLineTools, doctor: doctor(clt: false, claude: false)))
        #expect(!SetupFlow.shouldRerunSystem(after: .commandLineTools, doctor: DoctorReport(version: 1, checks: [])))
    }

    @Test func homebrewWaitRerunsOnlyOnceBrewIsThere() {
        // The tools are in while the Homebrew installer is open: re-running then would download and open it again.
        #expect(!SetupFlow.shouldRerunSystem(after: .homebrew, doctor: doctor(clt: true, claude: true)))
        let brew = DoctorReport(version: 1, checks: [DoctorCheck(id: "homebrew", ok: true, summary: "")])
        #expect(SetupFlow.shouldRerunSystem(after: .homebrew, doctor: brew))
        #expect(SetupFlow.SystemWait.homebrew.doctorChecks == "homebrew")
        #expect(SetupFlow.SystemWait.commandLineTools.doctorChecks == "clt,claude")
    }

    @Test func systemWaitComesFromTheReport() {
        let brew = SetupReport(step: "system", status: .needsUser, summary: "", data: ["waiting": "homebrew", "claude": "/x"])
        #expect(SetupFlow.systemWait(brew) == .homebrew)
        #expect(SetupFlow.systemWait(SetupReport(step: "system", status: .needsUser, summary: "", data: ["waiting": "clt"])) == .commandLineTools)
        #expect(SetupFlow.systemWait(SetupReport(step: "system", status: .needsUser, summary: "")) == .commandLineTools)
    }

    @Test func automaticRerunKeepsTheDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = SetupFlow.pollDeadline(current: nil, automaticRerun: false, now: start, limit: 1_800)
        #expect(first == start.addingTimeInterval(1_800))
        let later = start.addingTimeInterval(600)
        #expect(SetupFlow.pollDeadline(current: first, automaticRerun: true, now: later, limit: 1_800) == first)
        #expect(SetupFlow.pollDeadline(current: first, automaticRerun: false, now: later, limit: 1_800) == later.addingTimeInterval(1_800))
        #expect(SetupFlow.pollDeadline(current: nil, automaticRerun: true, now: later, limit: 1_800) == later.addingTimeInterval(1_800))
    }

    @Test func telegramConfiguredOnlyWhenTheDoctorNamesTheJob() {
        let none = DoctorReport(version: 1, checks: [DoctorCheck(id: "telegram", ok: true, summary: "", step: "telegram")])
        #expect(!SetupFlow.telegramConfigured(doctor: none))
        let stopped = DoctorReport(version: 1, checks: [
            DoctorCheck(id: "telegram", ok: false, summary: "", step: "telegram", data: ["job": "not_installed"]),
        ])
        #expect(SetupFlow.telegramConfigured(doctor: stopped))
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
