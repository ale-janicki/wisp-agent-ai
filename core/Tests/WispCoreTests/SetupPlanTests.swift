import Foundation
import Testing

@testable import WispCore

@Suite struct SetupPlanTests {
    private let gb: UInt64 = 1_000_000_000

    private func model(_ tag: String, size: UInt64, memory: UInt64, speed: String) -> LocalModel {
        LocalModel(
            tag: tag, name: tag.capitalized, params: "", sizeBytes: size * gb, memoryBytes: memory * gb, tier: "medio",
            contextTokens: 8192, speed: speed, limitations: "")
    }

    private var catalog: [LocalModel] {
        [
            model("small", size: 2, memory: 3, speed: "rapido"),
            model("qwen", size: 5, memory: 6, speed: "medio"),
            model("heavy", size: 9, memory: 10, speed: "lento"),
            model("huge", size: 40, memory: 45, speed: "lento"),
        ]
    }

    private func hardware(chip: String = "Apple M4", memory: UInt64 = 16, disk: UInt64 = 200) -> HardwareProfile {
        HardwareProfile(chip: chip, totalMemory: memory * (1 << 30), availableMemory: 0, freeDisk: disk * gb)
    }

    private func status(installed: [String] = [], active: String = "") -> LocalModelStatus {
        LocalModelStatus(
            models: catalog, diskMarginBytes: 10 * gb, backend: BackendStatus(kind: "mlx", available: true, running: false),
            installed: installed, active: active)
    }

    private func offer(
        hardware: HardwareProfile, status: LocalModelStatus, readiness: SetupReadiness = SetupReadiness()
    ) -> SetupOffer {
        let advice = LocalAdvisor.recommend(hardware: hardware, models: status.models, diskMargin: status.diskMarginBytes)
        return SetupOffer.make(hardware: hardware, recommendation: advice, status: status, readiness: readiness)
    }

    @Test func localIsTheDefaultEvenWhenClaudeAndCodexAreConnected() {
        let ready = SetupReadiness(claudeLoggedIn: true, codexLoggedIn: true)
        let result = offer(hardware: hardware(), status: status(), readiness: ready)
        #expect(result.defaultEngine == .local)
        #expect(result.note == nil)
        #expect(result.defaultModelTag == "qwen")
        #expect(result.option("qwen")?.line == "Qwen · 5,0 GB · roda sem internet")
    }

    @Test func menuItemsCarryNameSizeSpeedAndBadges() {
        let result = offer(hardware: hardware(), status: status(installed: ["small"]))
        #expect(result.options.map(\.id) == ["small", "qwen", "heavy", "huge"])
        #expect(result.options[0].menuTitle == "Small · 2,0 GB · rápido · Já baixado")
        #expect(result.options[1].menuTitle == "Qwen · 5,0 GB · médio · Recomendado")
        #expect(result.options[2].menuTitle == "Heavy · 9,0 GB · lento · Apertado")
        #expect(result.options[3].menuTitle == "Huge · 40,0 GB · lento · não cabe")
    }

    @Test func modelsThatDoNotFitAreDisabled() {
        let result = offer(hardware: hardware(), status: status())
        #expect(result.options[3].enabled == false)
        #expect(result.option("huge") == nil)
        #expect(result.options[2].enabled)
    }

    @Test func recommendedChoiceDownloadsAndActivatesIt() {
        let result = offer(hardware: hardware(), status: status())
        #expect(SetupPlan.steps(engine: .local, modelTag: "qwen", offer: result)
            == [.brain, .harness, .selectEngine(.local), .profile, .pullModel("qwen")])
    }

    @Test func lighterChoiceDownloadsTheLighterModel() {
        let result = offer(hardware: hardware(), status: status())
        #expect(SetupPlan.steps(engine: .local, modelTag: "small", offer: result).last == .pullModel("small"))
    }

    @Test func heavierChoiceDownloadsTheHeavierModel() {
        let result = offer(hardware: hardware(), status: status())
        #expect(SetupPlan.steps(engine: .local, modelTag: "heavy", offer: result).last == .pullModel("heavy"))
    }

    @Test func aModelThatDoesNotFitFallsBackToTheRecommended() {
        let result = offer(hardware: hardware(), status: status())
        #expect(SetupPlan.steps(engine: .local, modelTag: "huge", offer: result).last == .pullModel("qwen"))
    }

    @Test func downloadedChoiceIsUsedAndNotPulled() {
        let result = offer(hardware: hardware(), status: status(installed: ["small"]))
        #expect(result.option("small")?.line == "Small · já está neste Mac · roda sem internet")
        let steps = SetupPlan.steps(engine: .local, modelTag: "small", offer: result)
        #expect(steps == [.brain, .harness, .useModel("small"), .selectEngine(.local), .profile])
    }

    @Test func activeModelCountsAsOnDisk() {
        #expect(offer(hardware: hardware(), status: status(installed: ["qwen"], active: "qwen")).option("qwen")?.onDisk == true)
    }

    @Test func notAppleSiliconDefaultsToClaudeWithANote() {
        let result = offer(hardware: hardware(chip: "Intel Core i7"), status: status())
        #expect(result.options.isEmpty)
        #expect(result.localAvailable == false)
        #expect(result.defaultEngine == .claude)
        #expect(result.note == SetupOffer.noLocalNote)
    }

    @Test func noModelThatFitsDefaultsToClaude() {
        let result = offer(hardware: hardware(memory: 2), status: status())
        #expect(result.localAvailable == false)
        #expect(result.defaultEngine == .claude)
        #expect(result.note != nil)
    }

    @Test func notEnoughDiskDefaultsToClaude() {
        let result = offer(hardware: hardware(disk: 5), status: status())
        #expect(result.defaultEngine == .claude)
        #expect(result.options[0].badges == ["sem espaço"])
    }

    @Test func tightMemoryButNothingComfortableLeavesClaudeAsDefaultButLocalSelectable() {
        let result = offer(hardware: hardware(memory: 5), status: status())
        #expect(result.defaultEngine == .claude)
        #expect(result.option("small") != nil)
    }

    @Test func providerLineFollowsTheLogin() {
        let result = offer(hardware: hardware(), status: status(), readiness: SetupReadiness(claudeLoggedIn: true))
        #expect(result.providerLine(.claude) == "Conectado")
        #expect(result.providerLine(.codex) == "Conecte depois em Ajustes > Modelo")
        #expect(result.providerLine(.local) == nil)
    }

    @Test func configuredPiecesAreSkipped() {
        let ready = SetupReadiness(brainReady: true, harnessReady: true, profileReady: true)
        let result = offer(hardware: hardware(), status: status(installed: ["qwen"]), readiness: ready)
        #expect(SetupPlan.steps(engine: .local, modelTag: "qwen", offer: result) == [.useModel("qwen"), .selectEngine(.local)])
    }

    @Test func claudeAndCodexNeverDownloadAnything() {
        let result = offer(hardware: hardware(), status: status())
        for engine in [EngineKind.claude, .codex] {
            let steps = SetupPlan.steps(engine: engine, modelTag: "qwen", offer: result)
            #expect(steps == [.brain, .harness, .selectEngine(engine), .profile])
            #expect(!steps.contains { $0.isBackground })
        }
    }

    @Test func localWithoutAnyModelFallsBackToClaude() {
        let result = offer(hardware: hardware(chip: "Intel"), status: status())
        #expect(SetupPlan.steps(engine: .local, modelTag: nil, offer: result).contains(.selectEngine(.claude)))
    }

    private func rerun(_ current: SetupOffer.Current, installed: [String] = [], readiness: SetupReadiness = SetupReadiness(
        brainReady: true, harnessReady: true, profileReady: true)) -> SetupOffer {
        let status = status(installed: installed, active: current.localTag ?? "")
        let hardware = hardware()
        let advice = LocalAdvisor.recommend(hardware: hardware, models: status.models, diskMargin: status.diskMarginBytes)
        return SetupOffer.make(hardware: hardware, recommendation: advice, status: status, readiness: readiness, current: current)
    }

    @Test func rerunPreselectsTheCurrentEngine() {
        let claude = rerun(SetupOffer.Current(engine: .claude))
        #expect(claude.defaultEngine == .claude)
        #expect(claude.note == nil)
        let local = rerun(SetupOffer.Current(engine: .local, localTag: "small"), installed: ["small"])
        #expect(local.defaultEngine == .local)
        #expect(local.defaultModelTag == "small")
    }

    @Test func rerunWithoutChangeHasNoEngineNorDownloadSteps() {
        let claude = rerun(SetupOffer.Current(engine: .claude))
        #expect(SetupPlan.steps(engine: .claude, modelTag: claude.defaultModelTag, offer: claude).isEmpty)
        let local = rerun(SetupOffer.Current(engine: .local, localTag: "small"), installed: ["small"])
        #expect(SetupPlan.steps(engine: .local, modelTag: "small", offer: local).isEmpty)
    }

    @Test func rerunSwitchingToLocalDownloadsTheChosenModel() {
        let claude = rerun(SetupOffer.Current(engine: .claude))
        #expect(SetupPlan.steps(engine: .local, modelTag: "qwen", offer: claude) == [.selectEngine(.local), .pullModel("qwen")])
    }

    @Test func rerunChangingTheLocalModelUsesTheDownloadedOne() {
        let local = rerun(SetupOffer.Current(engine: .local, localTag: "small"), installed: ["small", "qwen"])
        #expect(SetupPlan.steps(engine: .local, modelTag: "qwen", offer: local) == [.useModel("qwen"), .selectEngine(.local)])
    }

    @Test func rerunSwitchingAwayFromLocalOnlySelectsTheEngine() {
        let local = rerun(SetupOffer.Current(engine: .local, localTag: "small"), installed: ["small"])
        #expect(SetupPlan.steps(engine: .codex, modelTag: "small", offer: local) == [.selectEngine(.codex)])
    }

    @Test func brainWithoutTheCommandLineToolsIsDeferredAndNamed() {
        let report = SetupReport(step: "brain", status: .failed, summary: "", data: ["step": "system"])
        #expect(SetupPlan.brainDeferred(report))
        #expect(!SetupPlan.brainDeferred(SetupReport(step: "brain", status: .failed, summary: "")))
        #expect(SetupPlan.brainDeferredNote.contains("xcode-select --install"))
    }

    @Test func stepOutcomes() {
        func report(_ status: SetupReport.Status, data: [String: String] = [:]) -> SetupReport {
            SetupReport(step: "x", status: status, summary: "", data: data)
        }
        #expect(SetupPlan.succeeded(.harness, report: report(.done)))
        #expect(SetupPlan.succeeded(.profile, report: report(.skipped)))
        #expect(!SetupPlan.succeeded(.harness, report: report(.failed)))
        #expect(!SetupPlan.succeeded(.harness, report: report(.needsUser)))
        #expect(SetupPlan.succeeded(.brain, report: report(.failed, data: ["step": "system"])))
        #expect(!SetupPlan.succeeded(.brain, report: report(.failed)))
        #expect(!SetupPlan.succeeded(.profile, report: report(.failed, data: ["step": "system"])))
    }

    @Test func readinessReadsTheDoctor() {
        let doctor = DoctorReport(version: 1, checks: [
            DoctorCheck(id: "claude_login", ok: true, summary: "", step: "login"),
            DoctorCheck(id: "brain", ok: false, summary: "", step: "brain"),
            DoctorCheck(id: "profile", ok: true, summary: "", step: "profile"),
        ])
        #expect(SetupReadiness(doctor: doctor) == SetupReadiness(claudeLoggedIn: true, profileReady: true))
    }
}
