import Foundation
import os
import WispCore

@MainActor
final class BrainColherService {
    private let scheduler: BrainColherScheduler

    init(wisp: URL) {
        let log = Logger(subsystem: AppIdentity.bundleID, category: "brain-colher")
        scheduler = BrainColherScheduler {
            guard FileManager.default.isExecutableFile(atPath: wisp.path) else { return }
            let environment = BrainColher.environment(
                wisp: wisp, base: ProcessInfo.processInfo.environment, loginPATH: ClaudeLocator.cachedLoginShellPATH)
            if let counts = await BrainColher.run(wisp: wisp, environment: environment) {
                log.info("colheita: colhidas=\(counts.harvested, privacy: .public) puladas=\(counts.skipped, privacy: .public)")
            } else {
                log.warning("colheita: sem resposta legível")
            }
        }
    }

    func start() { scheduler.start() }
    func stop() { scheduler.stop() }
}
