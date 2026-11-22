import Foundation

public enum EngineConnectState: Equatable, Sendable {
    case notInstalled
    case notConnected
    case waiting
    case connected
    case timedOut
}

public enum EngineLogin: Sendable {
    case claude
    case codex

    public init?(_ kind: EngineKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .local: return nil
        }
    }

    public var kind: EngineKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    public var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex login"
        }
    }

    public var doctorCheck: String {
        switch self {
        case .claude: "claude_login"
        case .codex: "codex_login"
        }
    }

    public var buttonTitle: String { "Conectar \(kind.displayName)" }

    public var hint: String {
        switch self {
        case .claude: "O Terminal abre com o Claude: digite /login e entre com a sua conta."
        case .codex: "O Terminal abre e pede o login do Codex."
        }
    }

    public var installCommand: String? {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: nil
        }
    }

    public var installURL: URL {
        switch self {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code")!
        case .codex: URL(string: "https://github.com/openai/codex")!
        }
    }

    public static let commandFilePrefix = "wisp-connect-"
    public static let commandFileExtension = "command"

    public var script: String {
        "#!/bin/zsh -l\nexport PATH=\"$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"\nclear\n\(command)\n"
    }

    public func commandFileName(token: String) -> String {
        "\(Self.commandFilePrefix)\(kind.rawValue)-\(token).\(Self.commandFileExtension)"
    }

    public static func isCommandFile(_ name: String) -> Bool {
        name.hasPrefix(commandFilePrefix) && name.hasSuffix(".\(commandFileExtension)")
    }
}

public struct EngineConnectFlow: Equatable, Sendable {
    public static let pollInterval: TimeInterval = 3
    public static let limit: TimeInterval = 600

    public private(set) var state: EngineConnectState
    private var waited: TimeInterval = 0

    public init(state: EngineConnectState = .notConnected) {
        self.state = state
    }

    public static func resolve(installed: Bool, loggedIn: Bool) -> EngineConnectState {
        guard installed else { return .notInstalled }
        return loggedIn ? .connected : .notConnected
    }

    public mutating func check(installed: Bool, loggedIn: Bool) {
        guard state != .waiting else {
            if loggedIn { state = .connected }
            return
        }
        state = Self.resolve(installed: installed, loggedIn: loggedIn)
    }

    public mutating func opened() {
        guard state == .notConnected || state == .timedOut else { return }
        waited = 0
        state = .waiting
    }

    public mutating func polled(loggedIn: Bool, after interval: TimeInterval = pollInterval) {
        guard state == .waiting else { return }
        if loggedIn {
            state = .connected
            return
        }
        waited += interval
        if waited >= Self.limit { state = .timedOut }
    }

    public mutating func stopped() {
        if state == .waiting { state = .notConnected }
    }
}
