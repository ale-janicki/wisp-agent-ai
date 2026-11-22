import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class ModelPickerModel {
    enum Job: Equatable {
        case idle
        case pulling(tag: String, completed: UInt64, total: UInt64)
    }

    static let shared = ModelPickerModel()

    private(set) var status: LocalModelStatus?
    private(set) var hardware = HardwareProfile.read()
    private(set) var job: Job = .idle
    private(set) var error: String?
    private(set) var recommendation: LocalRecommendation?
    private(set) var usingLocalAI = false

    @ObservationIgnored private let layout = RuntimeLayout(
        bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var stream: LineStream?
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "models")

    private init() {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        self.environment = environment
    }

    var busy: Bool { job != .idle }

    func fit(_ model: LocalModel) -> ModelFit {
        ModelFit.assess(
            model, on: hardware, diskMargin: status?.diskMarginBytes ?? 0, installed: status?.installed.contains(model.tag) == true)
    }

    func refresh() {
        hardware = HardwareProfile.read()
        let executable = layout.wisp
        let environment = environment
        Task {
            let result = await Task.detached {
                CommandRunner.run(executable: executable, arguments: ["local", "catalog"], environment: environment, timeout: 20)
            }.value
            if case .success(let output) = result, let parsed = LocalModelStatus.decode(output.stdout) {
                status = parsed
                recommendation = LocalAdvisor.recommend(hardware: hardware, models: parsed.models, diskMargin: parsed.diskMarginBytes)
            } else if status == nil {
                error = "Não consegui ler o catálogo de modelos."
            }
        }
    }

    func install(_ model: LocalModel) {
        guard !busy, let status else { return }
        if let problem = LocalAISetup.preflight(
            model: model, hardware: hardware, diskMargin: status.diskMarginBytes, installed: status.installed.contains(model.tag)) {
            error = problem
            return
        }
        guard status.backend.available else {
            error = "Este Wisp não tem o mlx-lm: atualize o Wisp para baixar modelos."
            return
        }
        error = nil
        let line = LineStream()
        stream = line
        job = .pulling(tag: model.tag, completed: 0, total: 0)
        Task {
            if await run(line, ["local", "pull", model.tag], tag: model.tag) { _ = await simple(["local", "use", model.tag], only: status.active.isEmpty) }
            finish()
        }
    }

    func useLocalAI(_ model: LocalModel) {
        guard !busy, let status else { return }
        if let problem = LocalAISetup.preflight(
            model: model, hardware: hardware, diskMargin: status.diskMarginBytes, installed: status.installed.contains(model.tag)) {
            error = problem
            return
        }
        guard status.backend.available else {
            error = "Este Wisp não tem o mlx-lm: atualize o Wisp para usar a IA local."
            return
        }
        error = nil
        usingLocalAI = true
        let steps = LocalAISetup.steps(modelInstalled: status.installed.contains(model.tag), tag: model.tag)
        let line = LineStream()
        stream = line
        job = .pulling(tag: model.tag, completed: 0, total: 0)
        Task {
            let outcome = await LocalAISetup.run(steps) { step in
                switch step {
                case .pull(let tag):
                    let pulling = LineStream()
                    stream = pulling
                    job = .pulling(tag: tag, completed: 0, total: 0)
                    if await run(pulling, ["local", "pull", tag], tag: tag) { return .done }
                    return pulling.wasCancelled ? .cancelled : .failed(error ?? "Não consegui baixar o modelo.")
                case .use(let tag):
                    return await simple(["local", "use", tag], only: true) ? .done : .failed("Não consegui ativar o modelo \(tag).")
                case .selectEngine:
                    return await simple(["config", "set", "engine", "local", "--json"], only: true, timeout: 90)
                        ? .done : .failed("Não consegui trocar o motor para a IA local.")
                }
            }
            if case .failed(let message) = outcome { error = message }
            usingLocalAI = false
            finish()
            EngineModel.shared.refresh()
        }
    }

    func setThinking(_ on: Bool) {
        guard !busy else { return }
        Task {
            _ = await simple(["local", "pensar", on ? "on" : "off"], only: true)
            refresh()
        }
    }

    func cancel() {
        stream?.cancel()
    }

    func use(_ model: LocalModel) {
        Task {
            _ = await simple(["local", "use", model.tag], only: true)
            refresh()
        }
    }

    private func finish() {
        job = .idle
        stream = nil
        refresh()
    }

    private func run(_ line: LineStream, _ arguments: [String], tag: String?) async -> Bool {
        let executable = layout.wisp
        let environment = environment
        let box = FailureBox()
        let result = await line.run(executable: executable, arguments: arguments, environment: environment) { text in
            guard let event = ModelJobEvent.decode(line: text) else { return }
            Task { @MainActor in self.apply(event, tag: tag, box: box) }
        }
        if line.wasCancelled { return false }
        if let message = box.message {
            error = message
            return false
        }
        switch result {
        case .failure(let failure):
            error = "Não consegui rodar o wisp: \(failure.localizedDescription)"
            return false
        case .success(let finished):
            if finished.status != 0 { error = finished.stderrTail.isEmpty ? "Não consegui concluir (código \(finished.status))." : finished.stderrTail }
            return finished.status == 0
        }
    }

    private func apply(_ event: ModelJobEvent, tag: String?, box: FailureBox) {
        switch event {
        case .progress(_, let completed, let total):
            if let tag { job = .pulling(tag: tag, completed: completed, total: total) }
        case .failed(let message): box.message = message
        case .done: break
        }
    }

    private func simple(_ arguments: [String], only: Bool, timeout: TimeInterval = 20) async -> Bool {
        guard only else { return false }
        let executable = layout.wisp
        let environment = environment
        let result = await Task.detached {
            CommandRunner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
        if case .success(let output) = result, output.status == 0, !output.timedOut { return true }
        log.error("wisp \(arguments.joined(separator: " "), privacy: .public) failed")
        return false
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var message: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
