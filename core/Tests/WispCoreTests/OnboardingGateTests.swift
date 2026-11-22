import Foundation
import Testing

@testable import WispCore

@Suite struct OnboardingGateTests {
    private let connected = EngineAccess(installed: true, loggedIn: true)
    private let absent = EngineAccess(installed: false, loggedIn: false)

    private func decide(
        _ engine: EngineKind, profileError: String? = nil, claude: EngineAccess? = nil, codex: EngineAccess? = nil,
        runtime: Bool = true, model: String? = nil, download: LocalDownload? = nil
    ) -> OnboardingState {
        OnboardingGate.decide(
            engine: engine, profileError: profileError, claude: claude ?? connected, codex: codex, localRuntimeReady: runtime,
            localActiveModel: model, localDownload: download)
    }

    @Test func localWithoutClaudeIsNotBlockedByClaude() {
        #expect(decide(.local, claude: absent, model: "gemma") == .ready)
        #expect(decide(.local, claude: absent, codex: absent, model: "gemma") == .ready)
        #expect(!decide(.local, claude: absent, model: "gemma").blocksInput)
    }

    @Test func claudeBranches() {
        #expect(decide(.claude) == .ready)
        #expect(decide(.claude, claude: absent) == .claudeMissing)
        #expect(decide(.claude, claude: EngineAccess(installed: true, loggedIn: false)) == .claudeLoggedOut)
        #expect(decide(.claude, claude: absent).detail == "Conecte o Claude em Ajustes > Modelo.")
    }

    @Test func claudeIgnoresLocalAndCodex() {
        #expect(decide(.claude, codex: absent, runtime: false) == .ready)
    }

    @Test func codexBranches() {
        #expect(decide(.codex, claude: absent, codex: connected) == .ready)
        #expect(decide(.codex, codex: absent) == .codexMissing)
        #expect(decide(.codex, codex: EngineAccess(installed: true, loggedIn: false)) == .codexLoggedOut)
        #expect(decide(.codex, codex: nil) == .ready)
        #expect(decide(.codex, codex: absent).detail == "Conecte o Codex em Ajustes > Modelo.")
    }

    @Test func localRuntimeNotReadyBlocksWithRetry() {
        let state = decide(.local, runtime: false, model: "gemma")
        #expect(state == .localRuntimeInstalling)
        #expect(state.detail == "O componente de IA local ainda está sendo instalado.")
        #expect(state.action == .retry)
    }

    @Test func localWithoutModelAsksToChoose() {
        let state = decide(.local)
        #expect(state == .localNeedsModel)
        #expect(state.detail == "Escolha um modelo em Ajustes > Modelo.")
        #expect(state.action == .openModelSettings)
        #expect(decide(.local, model: "") == .localNeedsModel)
    }

    @Test func localDownloadingBlocksSendingWithProgress() {
        let state = decide(.local, download: LocalDownload(model: "Gemma 3", percent: 42))
        #expect(state == .localDownloading(model: "Gemma 3", percent: 42))
        #expect(state.blocksInput)
        #expect(state.detail == "O Gemma 3 ainda está baixando (42%).")
        #expect(state.action == nil)
        #expect(decide(.local, download: LocalDownload(model: "Gemma 3")).detail == "O Gemma 3 ainda está baixando.")
    }

    @Test func localActiveModelWinsOverDownload() {
        #expect(decide(.local, model: "gemma", download: LocalDownload(model: "Outro", percent: 10)) == .ready)
    }

    @Test func runtimeNotReadyComesBeforeDownload() {
        #expect(decide(.local, runtime: false, download: LocalDownload(model: "X", percent: 1)) == .localRuntimeInstalling)
    }

    @Test func profileErrorBlocksEveryEngine() {
        for engine in EngineKind.allCases {
            let state = decide(engine, profileError: "toml quebrado", model: "gemma")
            #expect(state == .profileInvalid("toml quebrado"))
            #expect(state.detail == "toml quebrado")
            #expect(state.blocksInput)
        }
    }

    @Test func readyDoesNotBlock() {
        #expect(!OnboardingState.ready.blocksInput)
        #expect(OnboardingState.ready.action == nil)
    }

    @Test func percentIsIntegerAndClamped() {
        #expect(LocalDownload.percent(completed: 1, total: 3) == 33)
        #expect(LocalDownload.percent(completed: 5, total: 2) == 100)
        #expect(LocalDownload.percent(completed: 0, total: 0) == nil)
    }
}
