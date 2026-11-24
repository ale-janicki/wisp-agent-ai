import AppKit
import Darwin
import WispCore

/// The one terminal workspace of the app: the notch panel and the window show the same sessions.
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()

    let workspace: TerminalWorkspace

    private static let lastDirectoryKey = "terminal.lastDirectory"

    private init() {
        let defaults = UserDefaults.standard
        let memory = TerminalDirectory.Memory(
            load: { defaults.string(forKey: Self.lastDirectoryKey) },
            save: { defaults.set($0, forKey: Self.lastDirectoryKey) })
        let home = NSHomeDirectory()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        workspace = TerminalWorkspace(memory: memory, home: home) { directory in
            let shell = TerminalShell.resolve(shellVariable: Self.shellVariable())
            let env = TerminalEnvironment.build(
                base: ProcessInfo.processInfo.environment, shell: shell, home: home, user: NSUserName(), version: version)
            return TerminalSession(shell: shell, environment: env, directory: directory) { SwiftTermEngine() }
        }
    }

    /// `$SHELL`, or the login shell the system lists for this user when the app was started without one.
    private static func shellVariable() -> String? {
        if let value = ProcessInfo.processInfo.environment["SHELL"], !value.isEmpty { return value }
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }
}
