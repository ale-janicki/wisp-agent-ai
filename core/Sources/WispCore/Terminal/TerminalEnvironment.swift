import Foundation

/// The environment a terminal session's shell starts with. PATH is left to the login shell: an app opened from Finder has a bare one,
/// and the shell's own profile files rebuild it.
public enum TerminalEnvironment {
    public static let program = "Wisp"
    public static let defaultLang = "en_US.UTF-8"

    public static func build(base: [String: String], shell: TerminalShell, home: String, user: String, version: String? = nil) -> [String: String] {
        var env = base.filter { !isInherited($0.key) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = program
        if let version { env["TERM_PROGRAM_VERSION"] = version } else { env.removeValue(forKey: "TERM_PROGRAM_VERSION") }
        env["SHELL"] = shell.path
        env["HOME"] = home
        if env["USER"]?.isEmpty ?? true { env["USER"] = user }
        if env["LOGNAME"]?.isEmpty ?? true { env["LOGNAME"] = user }
        if let lang = env["LANG"], !lang.isEmpty {} else { env["LANG"] = defaultLang }
        return env
    }

    /// `KEY=value` lines in a stable order, the form `execve` takes.
    public static func lines(_ env: [String: String]) -> [String] {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }

    /// Never handed to the user's shell. Keys and config of the AI engines would point her own `claude` or `codex` at another
    /// account or a parent session, the Wisp runtime's own variables (`WISP_*`, `UV_*`, `PYTHONPATH`) are the app's business,
    /// and a terminal's stale size would fight the pty's.
    static func isInherited(_ key: String) -> Bool {
        RuntimeEnvironment.isInterpreterOverride(key)
            || key.hasPrefix("WISP_") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_")
            || ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "COLUMNS", "LINES"].contains(key)
    }
}
