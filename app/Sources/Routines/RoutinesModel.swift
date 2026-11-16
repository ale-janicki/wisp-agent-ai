import Foundation
import Observation
import WispCore

@MainActor @Observable
final class RoutinesModel {
    static let shared = RoutinesModel()

    struct Row: Identifiable, Equatable {
        var job: RoutineJob
        var status: Result<RoutineStatus, RoutineStatusError>
        var id: String { job.id }
    }

    enum State: Equatable {
        case loading
        case loaded([Row])
        case failed(String)
    }

    enum LogState: Equatable {
        case loading
        case loaded([String])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var toggling: String?
    private(set) var actionError: (label: String, message: String)?
    private(set) var log: LogState = .loading

    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var logGeneration = 0

    static let interval: Duration = .seconds(10)

    var runningCount: Int? {
        guard case .loaded(let rows) = state else { return nil }
        return rows.filter { (try? $0.status.get())?.state == .running }.count
    }

    func refresh(block: RoutinesBlock) {
        guard let registry = block.registry, let status = block.status else { return }
        readGeneration += 1
        let current = readGeneration
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) { Self.read(registry: registry, status: status) }.value
            guard let self, self.readGeneration == current else { return }
            self.state = state
        }
    }

    func toggle(_ row: Row, block: RoutinesBlock) {
        guard toggling == nil, let loaded = try? row.status.get().isLoaded,
              let template = loaded ? block.stop : block.start
        else { return }
        toggling = row.id
        actionError = nil
        let command = RoutineCommand.build(template, job: row.job)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { BlockCommand.run(command) }.value
            guard let self else { return }
            if case .failure(let error) = result {
                let verb = loaded ? "desligar" : "ligar"
                self.actionError = (row.id, "Não consegui \(verb) \(row.job.name): \(error.localizedDescription)")
            }
            self.toggling = nil
            self.refresh(block: block)
        }
    }

    func loadLog(path: String) {
        logGeneration += 1
        let current = logGeneration
        log = .loading
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { LogTail.read(path: path) }.value
            guard let self, self.logGeneration == current else { return }
            switch result {
            case .success(let lines): self.log = .loaded(lines)
            case .failure(.missing(let path)): self.log = .failed("Este log ainda não existe: \(path)")
            }
        }
    }

    nonisolated private static func read(registry: String, status template: String) -> State {
        let jobs: [RoutineJob]
        do {
            jobs = try RoutineRegistry.load(path: registry)
        } catch {
            return .failed("Não consegui ler as rotinas: \(error.localizedDescription)")
        }
        let rows = jobs.map { job -> Row in
            var job = job
            if job.logs.isEmpty, let data = FileManager.default.contents(atPath: job.plist) {
                job.logs = RoutineRegistry.logs(fromPlist: data)
            }
            let output = BlockCommand.run(RoutineCommand.build(template, job: job))
            return Row(job: job, status: RoutineStatusParser.interpret(output))
        }
        return .loaded(rows)
    }
}

extension RoutinesModel.Row {
    var summary: String {
        switch status {
        case .failure(let error): return error.message
        case .success(let status):
            var parts: [String] = []
            switch status.state {
            case .running: parts.append("rodando")
            case .waiting: parts.append("aguardando")
            case .unloaded: return "desligado"
            case .other(let raw): parts.append(raw)
            }
            if let pid = status.pid { parts.append("pid \(pid)") }
            if let runs = status.runs { parts.append(runs == 1 ? "1 execução" : "\(runs) execuções") }
            if let code = status.lastExitCode {
                parts.append("saída \(code)" + (status.lastExitReason.map { " \($0)" } ?? ""))
            }
            return parts.joined(separator: " · ")
        }
    }
}
