import Foundation

public struct CodexReadiness: Equatable, Sendable {
    public var installed: Bool
    public var loggedIn: Bool

    public var ready: Bool { installed && loggedIn }

    public init(installed: Bool, loggedIn: Bool) {
        self.installed = installed
        self.loggedIn = loggedIn
    }

    public func note(for kind: EngineKind = .codex) -> String {
        installed ? "o \(kind.displayName) não está com o login feito neste Mac; esta conversa roda no Claude"
            : "o \(kind.displayName) não está instalado neste Mac; esta conversa roda no Claude"
    }

    public static func check(configured: String?) -> CodexReadiness {
        guard let executable = try? CodexLocator.resolve(configured: configured) else {
            return CodexReadiness(installed: false, loggedIn: false)
        }
        var environment = ProcessInfo.processInfo.environment
        if let path = ClaudeLocator.cachedLoginShellPATH { environment["PATH"] = path }
        let result = CommandRunner.run(executable: executable, arguments: ["login", "status"], environment: environment, timeout: 10)
        guard case .success(let output) = result else { return CodexReadiness(installed: true, loggedIn: false) }
        return CodexReadiness(installed: true, loggedIn: output.status == 0 && !output.timedOut)
    }
}
