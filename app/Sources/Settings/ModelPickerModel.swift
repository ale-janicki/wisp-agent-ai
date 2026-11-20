import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class ModelPickerModel {
    enum Job: Equatable {
        case idle
        case installingOllama(completed: UInt64, total: UInt64)
        case pulling(tag: String, completed: UInt64, total: UInt64)
    }

    static let shared = ModelPickerModel()

    private(set) var status: LocalModelStatus?
    private(set) var hardware = HardwareProfile.read()
    private(set) var job: Job = .idle
    private(set) var error: String?

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
            } else if status == nil {
                error = "Não consegui ler o catálogo de modelos."
            }
        }
    }

    func install(_ model: LocalModel) {
        guard !busy, let status else { return }
        let fit = fit(model)
        if let short = fit.diskShortBy {
            error = "Falta espaço em disco: faltam \(ModelFit.gigabytes(short)) livres para baixar o \(model.name)."
            return
        }
        guard fit.level != .doesNotFit else {
            error = "O \(model.name) não cabe na memória deste Mac."
            return
        }
        error = nil
        let needsOllama = !status.ollama.installed
        let first = LineStream()
        stream = first
        job = needsOllama ? .installingOllama(completed: 0, total: 0) : .pulling(tag: model.tag, completed: 0, total: 0)
        Task {
            if needsOllama {
                guard await run(first, ["local", "install-ollama"], tag: nil) else { return finish() }
                job = .pulling(tag: model.tag, completed: 0, total: 0)
            }
            let second = needsOllama ? LineStream() : first
            stream = second
            if await run(second, ["local", "pull", model.tag], tag: model.tag) { _ = await simple(["local", "use", model.tag], only: status.active.isEmpty) }
            finish()
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
            job = tag.map { .pulling(tag: $0, completed: completed, total: total) } ?? .installingOllama(completed: completed, total: total)
        case .failed(let message): box.message = message
        case .done: break
        }
    }

    private func simple(_ arguments: [String], only: Bool) async -> Bool {
        guard only else { return false }
        let executable = layout.wisp
        let environment = environment
        let result = await Task.detached {
            CommandRunner.run(executable: executable, arguments: arguments, environment: environment, timeout: 20)
        }.value
        if case .success(let output) = result, output.status == 0 { return true }
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
