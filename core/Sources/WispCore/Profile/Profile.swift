import Foundation

public struct Persona: Codable, Sendable, Equatable {
    public var name: String
    public var avatar: String?
    public var user: String?
    public var language: String

    public init(name: String, avatar: String? = nil, user: String? = nil, language: String) {
        self.name = name
        self.avatar = avatar
        self.user = user
        self.language = language
    }
}

public struct AgentConfig: Codable, Sendable, Equatable {
    public var cwd: String
    public var model: String?
    public var claudePath: String?
    public var statusPrefix: String?

    public init(cwd: String, model: String? = nil, claudePath: String? = nil, statusPrefix: String? = nil) {
        self.cwd = cwd
        self.model = model
        self.claudePath = claudePath
        self.statusPrefix = statusPrefix
    }
}

public struct AlertsBlock: Codable, Sendable, Equatable {
    public var list: String?
    public var resolve: String?

    public init(list: String? = nil, resolve: String? = nil) {
        self.list = list
        self.resolve = resolve
    }
}

public struct TasksBlock: Codable, Sendable, Equatable {
    public var file: String?

    public init(file: String? = nil) {
        self.file = file
    }
}

public struct AgendaBlock: Codable, Sendable, Equatable {
    public var list: String?

    public init(list: String? = nil) {
        self.list = list
    }
}

public struct ProfileBlocks: Codable, Sendable, Equatable {
    public var alerts: AlertsBlock?
    public var tasks: TasksBlock?
    public var agenda: AgendaBlock?
    public var memory: MemoryBlock?
    public var routines: RoutinesBlock?
    public var telegram: TelegramBlock?
    public var usage: UsageBlock?

    public init(
        alerts: AlertsBlock? = nil, tasks: TasksBlock? = nil, agenda: AgendaBlock? = nil,
        memory: MemoryBlock? = nil, routines: RoutinesBlock? = nil, telegram: TelegramBlock? = nil,
        usage: UsageBlock? = nil
    ) {
        self.alerts = alerts
        self.tasks = tasks
        self.agenda = agenda
        self.memory = memory
        self.routines = routines
        self.telegram = telegram
        self.usage = usage
    }
}

public struct Profile: Codable, Sendable, Equatable {
    public var persona: Persona
    public var agent: AgentConfig
    public var blocks: ProfileBlocks?

    public init(persona: Persona, agent: AgentConfig, blocks: ProfileBlocks? = nil) {
        self.persona = persona
        self.agent = agent
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case persona, agent, blocks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        persona = try container.decode(Persona.self, forKey: .persona)
        agent = try container.decode(AgentConfig.self, forKey: .agent)
        blocks = try? container.decodeIfPresent(ProfileBlocks.self, forKey: .blocks)
    }

    public static let `default` = Profile(
        persona: Persona(name: "Wisp", avatar: nil, language: "en"),
        agent: AgentConfig(cwd: "~")
    )
}

public func expandTilde(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
    return path
}
