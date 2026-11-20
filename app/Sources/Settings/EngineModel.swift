import Foundation
import Observation
import WispCore

@MainActor @Observable
final class EngineModel {
    static let shared = EngineModel()

    private(set) var active: EngineKind = .claude
    private(set) var codex: CodexReadiness?
    private(set) var busy = false
    private(set) var error: String?

    @ObservationIgnored private let layout = RuntimeLayout(
        bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    @ObservationIgnored private let environment: [String: String]

    private init() {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UV_") && $0.key != "PYTHONPATH" }
        environment["WISP_RESOURCES"] = layout.src.path
        self.environment = environment
        active = EngineChoice.active()
    }

    func refresh() {
        active = EngineChoice.active()
        let wisp = layout.wisp.path
        let environment = environment
        Task {
            codex = await Task.detached { CodexReadiness.check(configured: nil, wispBinary: wisp, environment: environment) }.value
        }
    }

    func select(_ kind: EngineKind) {
        guard !busy, kind != active, AppSettings.shared.persists else { return }
        busy = true
        error = nil
        let executable = layout.wisp
        let environment = environment
        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: CommandRunner.run(
                        executable: executable, arguments: ["config", "set", "engine", kind.rawValue, "--json"],
                        environment: environment, timeout: 60))
                }
            }
            busy = false
            switch result {
            case .failure:
                error = "Não consegui rodar o wisp."
            case .success(let output):
                let report = try? JSONDecoder().decode(SetupReport.self, from: output.stdout)
                if let report, report.status != .failed {
                    error = nil
                } else {
                    error = report?.summary ?? (output.timedOut ? "O wisp demorou demais." : "O wisp não respondeu.")
                }
            }
            refresh()
        }
    }

    func status(of kind: EngineKind) -> String {
        switch kind {
        case .claude:
            return "É o motor padrão do Wisp."
        case .codex:
            guard let codex else { return "Conferindo o Codex…" }
            if codex.ready { return "Codex instalado e com login feito." }
            if codex.installed, !codex.loggedIn { return "Codex instalado, mas falta entrar: rode `codex login` no Terminal." }
            if codex.installed { return "Codex instalado, mas o envio de e-mail está sem a trava de aprovação: rode `wisp harness sync`. Enquanto isso o Wisp responde pelo Claude." }
            return "Codex não está instalado neste Mac. Enquanto isso o Wisp responde pelo Claude."
        }
    }
}
