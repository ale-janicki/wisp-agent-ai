import Foundation

public enum CodexLocator {
    public static func resolve(
        configured: String?, shell: String = "/bin/zsh", home: String = NSHomeDirectory()
    ) throws -> URL {
        let fm = FileManager.default
        if let configured, !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else { throw AgentError.configuredCodexNotExecutable(path: path) }
            return URL(fileURLWithPath: path)
        }
        if let found = ClaudeLocator.commandPath("codex", shell: shell), fm.isExecutableFile(atPath: found) {
            return URL(fileURLWithPath: found)
        }
        for path in [home + "/.local/bin/codex", home + "/.npm-global/bin/codex", home + "/.bun/bin/codex",
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw AgentError.codexNotFound
    }
}
