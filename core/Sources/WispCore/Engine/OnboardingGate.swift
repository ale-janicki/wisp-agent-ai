import Foundation

public struct EngineAccess: Equatable, Sendable {
    public var installed: Bool
    public var loggedIn: Bool

    public init(installed: Bool, loggedIn: Bool) {
        self.installed = installed
        self.loggedIn = loggedIn
    }
}

public struct LocalDownload: Equatable, Sendable {
    public var model: String
    public var percent: Int?

    public init(model: String, percent: Int? = nil) {
        self.model = model
        self.percent = percent
    }

    public static func percent(completed: UInt64, total: UInt64) -> Int? {
        guard total > 0 else { return nil }
        return Int(min(completed, total) * 100 / total)
    }
}

public enum OnboardingAction: Equatable, Sendable {
    case openModelSettings
    case retry
}

public enum OnboardingState: Equatable, Sendable {
    case ready
    case profileInvalid(String)
    case claudeMissing
    case claudeLoggedOut
    case codexMissing
    case codexLoggedOut
    case localRuntimeInstalling
    case localNeedsModel
    case localDownloading(model: String, percent: Int?)

    public var blocksInput: Bool { self != .ready }

    public var title: String {
        switch self {
        case .ready: ""
        case .profileInvalid: "Perfil inválido"
        case .claudeMissing, .claudeLoggedOut: "Conecte o Claude"
        case .codexMissing, .codexLoggedOut: "Conecte o Codex"
        case .localRuntimeInstalling: "IA local quase pronta"
        case .localNeedsModel: "Escolha um modelo"
        case .localDownloading: "Baixando o modelo"
        }
    }

    public var detail: String {
        switch self {
        case .ready: ""
        case .profileInvalid(let message): message
        case .claudeMissing, .claudeLoggedOut: "Conecte o Claude em Ajustes > Modelo."
        case .codexMissing, .codexLoggedOut: "Conecte o Codex em Ajustes > Modelo."
        case .localRuntimeInstalling: "O componente de IA local ainda está sendo instalado."
        case .localNeedsModel: "Escolha um modelo em Ajustes > Modelo."
        case .localDownloading(let model, let percent):
            percent.map { "O \(model) ainda está baixando (\($0)%)." } ?? "O \(model) ainda está baixando."
        }
    }

    public var action: OnboardingAction? {
        switch self {
        case .ready, .profileInvalid, .localDownloading: nil
        case .claudeMissing, .claudeLoggedOut, .codexMissing, .codexLoggedOut, .localNeedsModel: .openModelSettings
        case .localRuntimeInstalling: .retry
        }
    }
}

public enum OnboardingGate {
    public static func decide(
        engine: EngineKind,
        profileError: String?,
        claude: EngineAccess,
        codex: EngineAccess?,
        localRuntimeReady: Bool,
        localActiveModel: String?,
        localDownload: LocalDownload?
    ) -> OnboardingState {
        if let profileError { return .profileInvalid(profileError) }
        switch engine {
        case .claude:
            if !claude.installed { return .claudeMissing }
            return claude.loggedIn ? .ready : .claudeLoggedOut
        case .codex:
            guard let codex else { return .ready }
            if !codex.installed { return .codexMissing }
            return codex.loggedIn ? .ready : .codexLoggedOut
        case .local:
            guard localRuntimeReady else { return .localRuntimeInstalling }
            if localActiveModel?.isEmpty == false { return .ready }
            if let localDownload { return .localDownloading(model: localDownload.model, percent: localDownload.percent) }
            return .localNeedsModel
        }
    }
}
