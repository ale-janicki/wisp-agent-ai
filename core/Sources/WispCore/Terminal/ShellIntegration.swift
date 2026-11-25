import Foundation
import Security

/// How a shell is started: its arguments, argv[0] and the whole environment of the child.
public struct TerminalLaunch: Equatable, Sendable {
    public var arguments: [String]
    public var execName: String
    public var environment: [String: String]
    /// The shell will say where commands start and end, so the terminal can show blocks.
    public var integrated: Bool
    /// The secret every mark of this shell carries; nil for a plain launch.
    public var markNonce: String? = nil
}

/// The hooks that make the shell say where each command starts and ends, put in without touching a file of the user's. The scripts
/// ship with the app (`directory` holds `zsh/`, `bash/` and `fish/`).
public struct ShellIntegration: Sendable {
    public enum Kind: Equatable, Sendable {
        case zsh, bash, fish
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Hands the nonce to the hooks, which move it into an unexported shell variable before anything else runs.
    public static let nonceVariable = "WISP_MARK_NONCE"

    /// 128 random bits as hex, new for each shell. Nil if the system has no randomness to give (the shell then starts plain).
    public static func makeNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func kind(of shell: TerminalShell) -> Kind? {
        switch shell.name {
        case "zsh": .zsh
        case "bash": .bash
        case "fish": .fish
        default: nil
        }
    }

    /// The plain launch (a login shell, nothing injected) when `enabled` is false, the shell is not one of the three, the scripts are
    /// not there, or there is no nonce.
    public func launch(
        shell: TerminalShell, environment: [String: String], enabled: Bool, nonce: String? = ShellIntegration.makeNonce()
    ) -> TerminalLaunch {
        var env = environment
        env.removeValue(forKey: Self.nonceVariable)
        let plain = TerminalLaunch(arguments: shell.arguments, execName: shell.loginName, environment: env, integrated: false)
        guard enabled, let kind = Self.kind(of: shell), let nonce, !nonce.isEmpty else { return plain }
        env[Self.nonceVariable] = nonce
        switch kind {
        case .zsh:
            let zdotdir = directory.appendingPathComponent("zsh").path
            guard FileManager.default.fileExists(atPath: zdotdir + "/.zshenv") else { return plain }
            if let original = environment["ZDOTDIR"] { env["WISP_ORIG_ZDOTDIR"] = original } else { env.removeValue(forKey: "WISP_ORIG_ZDOTDIR") }
            env["WISP_ZDOTDIR"] = zdotdir
            env["ZDOTDIR"] = zdotdir
            return TerminalLaunch(arguments: shell.arguments, execName: shell.loginName, environment: env, integrated: true, markNonce: nonce)
        case .bash:
            let rc = directory.appendingPathComponent("bash/wisp.bashrc").path
            guard FileManager.default.fileExists(atPath: rc) else { return plain }
            // A login shell ignores --init-file, so bash starts as a plain interactive one and the script does the login work.
            return TerminalLaunch(arguments: ["--init-file", rc], execName: shell.name, environment: env, integrated: true, markNonce: nonce)
        case .fish:
            let data = directory.appendingPathComponent("fish").path
            guard FileManager.default.fileExists(atPath: data + "/fish/vendor_conf.d/wisp.fish") else { return plain }
            let original = environment["XDG_DATA_DIRS"] ?? ""
            env["WISP_XDG_DATA_DIRS_ORIG"] = original
            env["XDG_DATA_DIRS"] = data + ":" + (original.isEmpty ? "/usr/local/share:/usr/share" : original)
            return TerminalLaunch(arguments: shell.arguments, execName: shell.loginName, environment: env, integrated: true, markNonce: nonce)
        }
    }
}
