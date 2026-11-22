import Foundation

public enum EngineKind: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public protocol EngineSession: AnyObject, Sendable {
    var kind: EngineKind { get }
    var events: AsyncStream<SessionEvent> { get }
    var processIdentifier: Int32? { get }
    var routesApprovals: Bool { get }
    func start() async throws
    func send(_ text: String) async throws
    func respond(to request: PermissionRequest, _ decision: PermissionDecision) async throws
    func stop() async
}

public struct EngineLaunch: Sendable {
    public var kind: EngineKind
    public var executable: URL
    public var cwd: URL
    public var model: String?
    public var resume: String?
    public var permission: PermissionChoice?
    public var claudePermissionMode: String?
    public var instructions: String
    public var claudeSettingsPath: String?
    public var disallowedTools: [String]
    public var addDirs: [String]
    public var environment: [String: String]
    public var wispBinary: String?
    public var preflight: (@Sendable (String) -> CodexPreflight)?

    public init(
        kind: EngineKind, executable: URL, cwd: URL, model: String? = nil, resume: String? = nil,
        permission: PermissionChoice? = nil, claudePermissionMode: String? = nil, instructions: String = "",
        claudeSettingsPath: String? = nil, disallowedTools: [String] = [], addDirs: [String] = [],
        environment: [String: String] = [:], wispBinary: String? = nil,
        preflight: (@Sendable (String) -> CodexPreflight)? = nil
    ) {
        self.preflight = preflight
        self.wispBinary = wispBinary
        self.kind = kind
        self.executable = executable
        self.cwd = cwd
        self.model = model
        self.resume = resume
        self.permission = permission
        self.claudePermissionMode = claudePermissionMode
        self.instructions = instructions
        self.claudeSettingsPath = claudeSettingsPath
        self.disallowedTools = disallowedTools
        self.addDirs = addDirs
        self.environment = environment
    }
}

public enum EngineFactory {
    public static func make(_ launch: EngineLaunch) -> any EngineSession {
        switch launch.kind {
        case .claude:
            AgentSession(
                executable: launch.executable, cwd: launch.cwd, model: launch.model, resume: launch.resume,
                permissionMode: launch.claudePermissionMode, appendSystemPrompt: launch.instructions,
                settingsPath: launch.claudeSettingsPath, disallowedTools: launch.disallowedTools,
                environmentOverrides: launch.environment)
        case .codex:
            CodexSession(
                executable: launch.executable, cwd: launch.cwd, resume: launch.resume, permission: launch.permission,
                addDirs: launch.addDirs, instructions: launch.instructions, model: CodexCommand.configuredModel(), environmentOverrides: launch.environment,
                wispBinary: launch.wispBinary, preflight: launch.preflight)
        }
    }
}
