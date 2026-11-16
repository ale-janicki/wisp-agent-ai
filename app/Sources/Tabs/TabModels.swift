import Foundation
import Observation
import WispCore

@MainActor
final class TabSources {
    static let shared = TabSources()

    let tasks = TasksModel()
    let agenda = AgendaModel()
    var alerts: AlertsModel { Dashboard.shared.alerts }

    static let interval: Duration = .seconds(30)

    var alertCount: Int? {
        if case .loaded(let items) = alerts.state { return items.count }
        return nil
    }

    func refresh(profile: Profile) {
        if let file = profile.blocks?.tasks?.file, !file.isEmpty { tasks.refresh(file: file) }
        if let command = profile.blocks?.alerts?.list, !command.isEmpty { alerts.refresh(command: command) }
        if let command = profile.blocks?.agenda?.list, !command.isEmpty { agenda.refresh(command: command) }
    }
}

@MainActor @Observable
final class TasksModel {
    enum State: Equatable {
        case loading
        case loaded([TaskGroup])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var actionError: String?
    private(set) var completing: String?

    @ObservationIgnored private var generation = 0

    var openCount: Int? {
        if case .loaded(let groups) = state { return TaskList.openCount(groups) }
        return nil
    }

    func refresh(file: String) {
        generation += 1
        let current = generation
        let url = URL(fileURLWithPath: expandTilde(file))
        Task { [weak self] in
            let result = await Task.detached { () -> Result<[TaskGroup], Error> in
                Result { TaskList.parse(try String(contentsOf: url, encoding: .utf8)) }
            }.value
            guard let self, self.generation == current else { return }
            switch result {
            case .success(let groups): self.state = .loaded(groups)
            case .failure: self.state = .failed("Não consegui ler \(url.lastPathComponent)")
            }
        }
    }

    func complete(_ item: TaskItem, file: String) {
        guard completing == nil else { return }
        completing = item.id
        actionError = nil
        let url = URL(fileURLWithPath: expandTilde(file))
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do {
                    try TaskList.complete(item, in: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.completing = nil
            if let failure { self.actionError = "Não consegui marcar como feito: \(failure)" }
            self.refresh(file: file)
        }
    }
}

@MainActor @Observable
final class AgendaModel {
    enum State: Equatable {
        case loading
        case loaded([AgendaEvent])
        case failed(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored private var running = false
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedCommand: String?

    private static let maxAge: TimeInterval = 120

    var remaining: Int? {
        if case .loaded(let events) = state { return AgendaList.remaining(events) }
        return nil
    }

    func refresh(command: String, force: Bool = false) {
        guard !running else { return }
        if !force, loadedCommand == command, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge { return }
        running = true
        Task { [weak self] in
            let result = await Task.detached { BlockCommand.run(command) }.value
            guard let self else { return }
            self.running = false
            self.loadedAt = Date()
            self.loadedCommand = command
            switch result {
            case .success(let data):
                do {
                    self.state = .loaded(try AgendaList.parse(data))
                } catch {
                    self.state = .failed("\(BlockCommandName.of(command)) não tem saída JSON")
                }
            case .failure(let error):
                self.state = .failed("Não consegui ler a agenda: \(error.localizedDescription)")
            }
        }
    }
}

enum BlockCommandName {
    static func of(_ command: String) -> String {
        command.split(separator: " ").prefix { !$0.hasPrefix("-") }.joined(separator: " ")
    }
}
