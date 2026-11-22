import AppKit
import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class SetupModel {
    enum Phase: Equatable {
        case loading
        case ready
        case running(String)
        case failed(String)
        case done
    }

    private(set) var phase: Phase = .loading
    private(set) var offer: SetupOffer?
    private(set) var hardware = HardwareProfile.read()
    var engine: EngineKind = .local
    var modelTag: String?

    let wisp: URL
    let homeOverride: URL?
    let existingInstall: Bool

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "setup")

    init(wisp: URL, homeOverride: URL? = nil, existingInstall: Bool = false) {
        self.wisp = wisp
        self.homeOverride = homeOverride
        self.existingInstall = existingInstall
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var stateURL: URL {
        if let homeOverride {
            return homeOverride.appendingPathComponent("Library/Application Support/Wisp/setup.json")
        }
        return Self.defaultStateURL
    }

    static var defaultStateURL: URL { ConversationStore.defaultDirectory.appendingPathComponent("setup.json") }

    // MARK: Reading the Mac

    func load() async {
        phase = .loading
        hardware = HardwareProfile.read()
        let readiness = await readinessFromDoctor() ?? SetupReadiness()
        let status = await catalog()
        let advice = status.map {
            LocalAdvisor.recommend(hardware: hardware, models: $0.models, diskMargin: $0.diskMarginBytes)
        }
        let offer = SetupOffer.make(hardware: hardware, recommendation: advice, status: status, readiness: readiness)
        self.offer = offer
        engine = offer.defaultEngine
        modelTag = offer.defaultModelTag
        phase = .ready
        if homeOverride == nil { ModelPickerModel.shared.refresh() }
    }

    private func readinessFromDoctor() async -> SetupReadiness? {
        let arguments = ["doctor", "--json", "--only", SetupReadiness.doctorChecks]
        guard case .success(let output) = await execute(arguments, timeout: 40), !output.timedOut,
              let report = try? JSONDecoder().decode(DoctorReport.self, from: output.stdout) else { return nil }
        return SetupReadiness(doctor: report)
    }

    private func catalog() async -> LocalModelStatus? {
        guard case .success(let output) = await execute(["local", "catalog"], timeout: 20), !output.timedOut else { return nil }
        return LocalModelStatus.decode(output.stdout)
    }

    // MARK: Começar

    @discardableResult
    func begin() async -> Bool {
        guard let offer, !isRunning else { return false }
        phase = .running("Conferindo o seu Mac")
        let readiness = await readinessFromDoctor() ?? offer.readiness
        let current = SetupOffer(options: offer.options, readiness: readiness)
        for action in SetupPlan.steps(engine: engine, modelTag: modelTag, offer: current) {
            if case .pullModel(let tag) = action {
                startDownload(tag)
                continue
            }
            phase = .running(Self.label(action))
            if let problem = await perform(action) {
                phase = .failed(problem)
                return false
            }
        }
        finish()
        phase = .done
        return true
    }

    private static func label(_ action: SetupAction) -> String {
        switch action {
        case .brain: "Criando o seu cérebro"
        case .harness: "Instalando as ferramentas"
        case .profile: "Montando o seu perfil"
        case .useModel, .selectEngine, .pullModel: "Ligando o motor"
        }
    }

    private func perform(_ action: SetupAction) async -> String? {
        switch action {
        case .brain: await report(action, ["setup", "brain", "--json"], timeout: 120)
        case .harness: await report(action, ["setup", "harness", "--json"], timeout: 180)
        case .profile: await report(action, ["setup", "profile", "--name", "Wisp", "--json"], timeout: 60)
        case .selectEngine(let kind): await report(action, ["config", "set", "engine", kind.rawValue, "--json"], timeout: 120)
        case .useModel(let tag): await plain(["local", "use", tag])
        case .pullModel: nil
        }
    }

    private func report(_ action: SetupAction, _ arguments: [String], timeout: TimeInterval) async -> String? {
        switch await execute(arguments, timeout: timeout) {
        case .failure:
            return "Não consegui rodar o comando do Wisp."
        case .success(let output):
            if output.timedOut { return "O passo demorou demais." }
            guard let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout) else {
                return "O Wisp não entendeu a resposta deste passo."
            }
            guard SetupPlan.succeeded(action, report: report) else { return Self.sentence(report.summary) }
            record(action)
            return nil
        }
    }

    private func plain(_ arguments: [String]) async -> String? {
        guard case .success(let output) = await execute(arguments, timeout: 30), output.status == 0, !output.timedOut else {
            return "Não consegui ativar o modelo."
        }
        return nil
    }

    private func startDownload(_ tag: String) {
        guard homeOverride == nil else { return }
        let picker = ModelPickerModel.shared
        guard let model = picker.status?.models.first(where: { $0.tag == tag }) else {
            log.error("download not started: catalog not loaded for \(tag, privacy: .public)")
            return
        }
        picker.install(model)
    }

    private func finish() {
        var state = SetupFlow.persisted(try? SetupState.load(from: stateURL), existingInstall: existingInstall, now: Date())
        state.finishedAt = Date()
        state.completed.insert("done")
        do { try state.save(to: stateURL) } catch { log.error("setup state not saved: \(error.localizedDescription, privacy: .public)") }
        if homeOverride == nil { LoginItemModel.shared.sync(setupFinished: true) }
    }

    // MARK: Plumbing

    private func record(_ action: SetupAction) {
        let name: String
        switch action {
        case .brain: name = "brain"
        case .harness: name = "harness"
        case .profile: name = "profile"
        case .selectEngine, .useModel, .pullModel: return
        }
        var state = SetupFlow.persisted(try? SetupState.load(from: stateURL), existingInstall: existingInstall, now: Date())
        state.completed.insert(name)
        do { try state.save(to: stateURL) } catch { log.error("setup state not saved: \(error.localizedDescription, privacy: .public)") }
    }

    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        let runtimeRoot = wisp.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        environment["WISP_RESOURCES"] = runtimeRoot.appendingPathComponent("src").path
        if let homeOverride {
            environment = environment.filter { !$0.key.hasPrefix("XDG_") && $0.key != "WISP_CONFIG" }
            environment["HOME"] = homeOverride.path
        }
        return environment
    }

    private func execute(_ arguments: [String], timeout: TimeInterval) async -> Result<CommandOutput, BlockCommandError> {
        let executable = wisp
        let environment = childEnvironment()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CommandRunner.run(
                    executable: executable, arguments: arguments, environment: environment, timeout: timeout))
            }
        }
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capitalized = first.uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") || capitalized.hasSuffix("?") ? capitalized : capitalized + "."
    }

    #if DEBUG
    func preview(offer: SetupOffer, hardware: HardwareProfile, phase: Phase = .ready) {
        self.offer = offer
        self.hardware = hardware
        self.phase = phase
        engine = offer.defaultEngine
        modelTag = offer.defaultModelTag
    }
    #endif
}
