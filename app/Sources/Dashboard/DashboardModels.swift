import Foundation
import Observation
import os
import WispCore

@MainActor
final class Dashboard {
    static let shared = Dashboard()

    let usage = UsageModel()
    let alerts = AlertsModel()
}

@MainActor @Observable
final class UsageModel {
    private(set) var summary: UsageSummary?
    private(set) var fileLimits: PlanLimitsSnapshot?
    private(set) var ownLimits: PlanLimitsSnapshot?

    var limits: PlanLimitsSnapshot? { PlanLimitsSnapshot.newest(fileLimits, ownLimits) }

    @ObservationIgnored private var loading = false
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private let index = UsageIndex()
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "usage")

    private static let maxAge: TimeInterval = 60

    func reloadLimits(path: String?) {
        guard let path, !path.isEmpty else { return }
        let snapshot = PlanLimitsSnapshot.read(path: path)
        if snapshot != fileLimits { fileLimits = snapshot }
    }

    func noteOwn(_ limit: RateLimit?) {
        guard let limit, limit.fiveHour != nil || limit.sevenDay != nil else { return }
        ownLimits = PlanLimitsSnapshot(limit: limit, capturedAt: Date())
    }

    func refreshIfStale() {
        guard !loading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge { return }
        loading = true
        Task { [weak self] in
            let started = Date()
            let index = self?.index
            let summary = await Task.detached(priority: .utility) { index?.summary() }.value
            guard let self, let summary else { return }
            self.log.info("usage aggregated in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            self.summary = summary
            self.loadedAt = Date()
            self.loading = false
        }
    }
}

@MainActor @Observable
final class AlertsModel {
    enum State: Equatable {
        case loading
        case loaded([AlertItem])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var resolving: String?
    private(set) var actionError: String?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedCommand: String?
    @ObservationIgnored var onLoaded: (([AlertItem]) -> Void)?

    static let interval: Duration = .seconds(30)

    func refresh(command: String, force: Bool = false) {
        guard !running else {
            if force { rerun = true }
            return
        }
        if !force, loadedCommand == command, let loadedAt, Date().timeIntervalSince(loadedAt) < 25 { return }
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
                    let items = try AlertList.parse(data)
                    self.state = .loaded(items)
                    self.onLoaded?(items)
                } catch {
                    self.state = .failed("\(Self.name(of: command)) não tem saída JSON")
                }
            case .failure(let error):
                self.state = .failed("Não consegui ler os alertas: \(error.localizedDescription)")
            }
            if self.rerun {
                self.rerun = false
                self.refresh(command: command, force: true)
            }
        }
    }

    func resolve(_ item: AlertItem, template: String, listCommand: String) {
        guard resolving == nil else { return }
        resolving = item.id
        actionError = nil
        let command = CommandTemplate.fill(template, ["id": item.id])
        Task { [weak self] in
            let result = await Task.detached { BlockCommand.run(command) }.value
            guard let self else { return }
            self.resolving = nil
            if case .failure(let error) = result {
                self.actionError = "Não consegui atualizar o lembrete: \(error.localizedDescription)"
            }
            self.refresh(command: listCommand, force: true)
        }
    }

    private static func name(of command: String) -> String {
        command.split(separator: " ").prefix { !$0.hasPrefix("-") }.joined(separator: " ")
    }
}
