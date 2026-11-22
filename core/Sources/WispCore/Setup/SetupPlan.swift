import Foundation

public struct SetupReadiness: Equatable, Sendable {
    public static let doctorChecks = "claude_login,codex_login,brain,harness,profile"

    public var claudeLoggedIn: Bool
    public var codexLoggedIn: Bool
    public var brainReady: Bool
    public var harnessReady: Bool
    public var profileReady: Bool

    public init(
        claudeLoggedIn: Bool = false, codexLoggedIn: Bool = false, brainReady: Bool = false, harnessReady: Bool = false,
        profileReady: Bool = false
    ) {
        self.claudeLoggedIn = claudeLoggedIn
        self.codexLoggedIn = codexLoggedIn
        self.brainReady = brainReady
        self.harnessReady = harnessReady
        self.profileReady = profileReady
    }

    public init(doctor: DoctorReport) {
        func ok(_ id: String) -> Bool { doctor.checks.first { $0.id == id }?.ok == true }
        self.init(
            claudeLoggedIn: ok("claude_login"), codexLoggedIn: ok("codex_login"), brainReady: ok("brain"),
            harnessReady: ok("harness"), profileReady: ok("profile"))
    }
}

public struct SetupOffer: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        public var tag: String
        public var name: String
        public var sizeBytes: UInt64
        public var speed: String
        public var onDisk: Bool
        public var recommended: Bool
        public var fit: FitLevel
        public var diskShort: Bool

        public var id: String { tag }
        public var enabled: Bool { fit != .doesNotFit && (onDisk || !diskShort) }

        public var label: String { "\(name) · \(ModelFit.gigabytes(sizeBytes)) · \(speed)" }

        public var badges: [String] {
            var badges: [String] = []
            if recommended { badges.append("Recomendado") }
            if onDisk { badges.append("Já baixado") }
            if fit == .doesNotFit {
                badges.append("não cabe")
            } else if diskShort, !onDisk {
                badges.append("sem espaço")
            } else if fit == .tight {
                badges.append("Apertado")
            }
            return badges
        }

        public var menuTitle: String { ([label] + badges).joined(separator: " · ") }

        public var line: String {
            onDisk ? "\(name) · já está neste Mac · roda sem internet" : "\(name) · \(ModelFit.gigabytes(sizeBytes)) · roda sem internet"
        }
    }

    public static let noLocalNote = "Este Mac não roda a IA local. Conecte o Claude ou o Codex em Ajustes > Modelo."
    public static let connected = "Conectado"
    public static let connectLater = "Conecte depois em Ajustes > Modelo"

    public var options: [Option]
    public var readiness: SetupReadiness

    public var recommended: Option? { options.first { $0.recommended && $0.enabled } }
    public var localAvailable: Bool { options.contains { $0.enabled } }
    public var defaultEngine: EngineKind { recommended == nil ? .claude : .local }
    public var defaultModelTag: String? { (recommended ?? options.first { $0.enabled })?.tag }
    public var note: String? { recommended == nil ? Self.noLocalNote : nil }

    public init(options: [Option], readiness: SetupReadiness) {
        self.options = options
        self.readiness = readiness
    }

    public func option(_ tag: String?) -> Option? {
        guard let tag else { return nil }
        return options.first { $0.tag == tag && $0.enabled }
    }

    public static func make(
        hardware: HardwareProfile, recommendation: LocalRecommendation?, status: LocalModelStatus?, readiness: SetupReadiness
    ) -> SetupOffer {
        guard LocalAdvisor.appleSilicon(hardware.chip), let status else { return SetupOffer(options: [], readiness: readiness) }
        let options = status.models.map { model -> Option in
            let presence = status.presence(of: model.tag)
            let onDisk = presence == .downloaded || presence == .inUse
            let fit = ModelFit.assess(model, on: hardware, diskMargin: status.diskMarginBytes, installed: onDisk)
            return Option(
                tag: model.tag, name: model.name, sizeBytes: model.sizeBytes, speed: speedWord(model.speed), onDisk: onDisk,
                recommended: recommendation?.best?.tag == model.tag, fit: fit.level, diskShort: fit.diskShortBy != nil)
        }
        return SetupOffer(options: options, readiness: readiness)
    }

    static func speedWord(_ speed: String) -> String {
        switch speed {
        case "rapido": "rápido"
        case "medio": "médio"
        case "lento": "lento"
        default: speed
        }
    }

    public func providerLine(_ engine: EngineKind) -> String? {
        switch engine {
        case .claude: readiness.claudeLoggedIn ? Self.connected : Self.connectLater
        case .codex: readiness.codexLoggedIn ? Self.connected : Self.connectLater
        case .local: nil
        }
    }
}

public enum SetupAction: Equatable, Sendable {
    case brain, harness, profile
    case useModel(String)
    case selectEngine(EngineKind)
    case pullModel(String)

    public var isBackground: Bool {
        if case .pullModel = self { return true }
        return false
    }
}

public enum SetupPlan {
    public static func steps(engine: EngineKind, modelTag: String?, offer: SetupOffer) -> [SetupAction] {
        let readiness = offer.readiness
        let local = engine == .local ? (offer.option(modelTag) ?? offer.option(offer.defaultModelTag)) : nil
        let chosen: EngineKind = engine == .local && local == nil ? .claude : engine
        var steps: [SetupAction] = []
        if !readiness.brainReady { steps.append(.brain) }
        if !readiness.harnessReady { steps.append(.harness) }
        if let local, local.onDisk { steps.append(.useModel(local.tag)) }
        steps.append(.selectEngine(chosen))
        if !readiness.profileReady { steps.append(.profile) }
        if let local, !local.onDisk { steps.append(.pullModel(local.tag)) }
        return steps
    }

    public static func succeeded(_ action: SetupAction, report: SetupReport) -> Bool {
        switch report.status {
        case .done, .skipped: true
        case .needsUser: false
        case .failed: action == .brain && report.data["step"] == "system"
        }
    }
}
