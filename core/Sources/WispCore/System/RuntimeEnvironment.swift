import Foundation

/// What a child process must not inherit from the app's own environment, in one place.
public enum RuntimeEnvironment {
    /// The interpreter overrides that would point a child at another Python or another uv: dropped by every spawn that runs
    /// the Wisp runtime, and by the terminal.
    public static func isInterpreterOverride(_ key: String) -> Bool {
        key.hasPrefix("UV_") || key == "PYTHONPATH"
    }

    /// The environment for a child that runs the Wisp runtime: the app's own, without the interpreter overrides.
    public static func forRuntime(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.filter { !isInterpreterOverride($0.key) }
    }
}
