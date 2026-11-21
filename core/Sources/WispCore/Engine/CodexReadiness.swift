import Foundation

public struct CodexReadiness: Equatable, Sendable {
    public var installed: Bool
    public var loggedIn: Bool

    public var sendGateOK: Bool
    public var projectProblem: String?

    public var ready: Bool { installed && loggedIn && sendGateOK && projectProblem == nil }

    public init(installed: Bool, loggedIn: Bool, sendGateOK: Bool = true, projectProblem: String? = nil) {
        self.installed = installed
        self.loggedIn = loggedIn
        self.sendGateOK = sendGateOK
        self.projectProblem = projectProblem
    }

    public func note(for kind: EngineKind = .codex) -> String {
        if installed, loggedIn, sendGateOK, let projectProblem {
            return "o \(kind.displayName) não roda aqui: \(projectProblem); esta conversa roda no Claude"
        }
        if installed, loggedIn, !sendGateOK {
            return "o \(kind.displayName) está com o envio de e-mail sem a trava de aprovação; rode `wisp harness sync`; esta conversa roda no Claude"
        }
        return installed ? "o \(kind.displayName) não está com o login feito neste Mac; esta conversa roda no Claude"
            : "o \(kind.displayName) não está instalado neste Mac; esta conversa roda no Claude"
    }

    public static func sendGate(wispBinary: String?, environment: [String: String]) -> Bool {
        guard let wispBinary, !wispBinary.isEmpty else { return false }
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: wispBinary), arguments: ["codex", "check"], environment: environment, timeout: 15)
        guard case .success(let output) = result, output.status == 0, !output.timedOut,
              let verdict = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any] else { return false }
        return verdict["ready"] as? Bool == true
    }

    public static let projectUnchecked = "não consegui conferir as configurações do Codex desta pasta"

    public static func projectProblem(wispBinary: String?, environment: [String: String], workspace: String) -> String? {
        guard let wispBinary, !wispBinary.isEmpty else { return projectUnchecked }
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: wispBinary), arguments: ["codex", "check", "--workspace", workspace],
            environment: environment, timeout: 15)
        guard case .success(let output) = result, !output.timedOut,
              let verdict = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any],
              verdict["ready"] is Bool else { return projectUnchecked }
        guard let project = verdict["project"] as? String, !project.isEmpty else { return nil }
        return project
    }

    public static func check(
        configured: String?, wispBinary: String?, environment: [String: String] = [:], workspace: String? = nil
    ) -> CodexReadiness {
        guard let executable = try? CodexLocator.resolve(configured: configured) else {
            return CodexReadiness(installed: false, loggedIn: false)
        }
        let launchEnvironment = CodexCommand.environment(executable: executable, overrides: environment)
        let result = CommandRunner.run(executable: executable, arguments: ["login", "status"], environment: launchEnvironment, timeout: 10)
        guard case .success(let output) = result else { return CodexReadiness(installed: true, loggedIn: false) }
        let loggedIn = output.status == 0 && !output.timedOut
        guard loggedIn else { return CodexReadiness(installed: true, loggedIn: false) }
        return CodexReadiness(
            installed: true, loggedIn: true, sendGateOK: sendGate(wispBinary: wispBinary, environment: launchEnvironment),
            projectProblem: workspace.flatMap { projectProblem(wispBinary: wispBinary, environment: launchEnvironment, workspace: $0) })
    }
}
