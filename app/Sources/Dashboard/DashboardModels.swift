import Foundation
import Observation
import os
import WispCore

@MainActor
final class Dashboard {
    static let shared = Dashboard()

    let usage = UsageModel()
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
