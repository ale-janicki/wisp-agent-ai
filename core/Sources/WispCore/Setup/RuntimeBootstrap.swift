import Foundation

public struct RuntimeLayout: Sendable {
    public let bundle: URL
    public let home: URL

    public init(bundle: URL, home: URL) {
        self.bundle = bundle
        self.home = home
    }

    public var bundled: URL { bundle.appendingPathComponent("Contents/Resources/runtime", isDirectory: true) }
    public var root: URL { home.appendingPathComponent(".local/share/wisp/runtime", isDirectory: true) }
    public var src: URL { root.appendingPathComponent("src", isDirectory: true) }
    public var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    public var wisp: URL { venv.appendingPathComponent("bin/wisp") }
    public var versionFile: URL { root.appendingPathComponent("VERSION") }
}

public enum RuntimeBootstrap {
    /// VERSION is written last, so an interrupted install has no installed version and retries.
    public static func needsInstall(bundledVersion: String?, installedVersion: String?) -> Bool {
        guard let bundledVersion else { return false }
        return bundledVersion != installedVersion
    }

    public static func uvArguments(_ layout: RuntimeLayout) -> [String] {
        ["sync", "--frozen", "--no-dev", "--all-packages", "--project", layout.src.path]
    }

    public static func uvEnvironment(_ layout: RuntimeLayout) -> [String: String] {
        [
            "UV_PROJECT_ENVIRONMENT": layout.venv.path,
            "UV_PYTHON_INSTALL_DIR": layout.root.appendingPathComponent("python").path,
            "UV_CACHE_DIR": layout.root.appendingPathComponent("cache").path,
            "UV_PYTHON": "3.13",
            "UV_LOCK_TIMEOUT": String(RuntimeSync.lockTimeoutSeconds),
            "TMPDIR": layout.root.appendingPathComponent("tmp").path,
            "WISP_RESOURCES": layout.src.path,
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
    }

    /// The environment to hand to `CommandRunner` for uv: `CommandRunner` replaces the whole environment, so callers
    /// must use this (base = `ProcessInfo.processInfo.environment`, which keeps PATH, HOME, proxies and SSL_*), never
    /// `uvEnvironment` alone. The uv keys win over the base.
    public static func processEnvironment(_ layout: RuntimeLayout, base: [String: String]) -> [String: String] {
        base.merging(uvEnvironment(layout)) { _, uv in uv }
    }
}
