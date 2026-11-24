import Foundation

/// The shell a terminal session runs: the user's `$SHELL` as a login shell, `/bin/zsh` when that is missing or unusable.
public struct TerminalShell: Equatable, Sendable {
    public static let fallbackPath = "/bin/zsh"
    private static let refused: Set<String> = ["false", "nologin"]

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// argv[0] with a leading dash: the convention that makes zsh, bash, fish and sh read their login files.
    public var loginName: String { "-" + name }

    public var arguments: [String] { [] }

    public static func resolve(shellVariable: String?, isUsable: (String) -> Bool = TerminalShell.isUsable) -> TerminalShell {
        if let value = shellVariable?.trimmingCharacters(in: .whitespaces), isUsable(value) {
            return TerminalShell(path: value)
        }
        return TerminalShell(path: fallbackPath)
    }

    public static func isUsable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !refused.contains((path as NSString).lastPathComponent) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
