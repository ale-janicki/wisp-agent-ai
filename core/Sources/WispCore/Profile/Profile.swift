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

public enum SoulSource: String, Codable, Sendable, CaseIterable {
    case wisp
    /// The user's own assistant config (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`); Wisp injects nothing.
    case assistant
    /// The assistant config loads as usual and the Wisp soul is appended on top.
    case both
}

public enum SoulTone: String, Codable, Sendable, CaseIterable {
    case direto
    case caloroso
    case formal
}

/// Where the personality comes from and how it sounds. The CLI (`wisp soul render`) turns it into text; every field decodes tolerantly.
public struct Soul: Codable, Sendable, Equatable {
    /// nil until the user chooses: the CLI then picks `assistant` when `~/.claude` is managed outside Wisp, else `wisp`.
    public var source: SoulSource?
    public var tone: SoulTone
    public var emojis: Bool
    public var extra: String

    public init(source: SoulSource? = nil, tone: SoulTone = .direto, emojis: Bool = false, extra: String = "") {
        self.source = source
        self.tone = tone
        self.emojis = emojis
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case source, tone, emojis, extra
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? container.decodeIfPresent(SoulSource.self, forKey: .source)) ?? nil
        tone = (try? container.decodeIfPresent(SoulTone.self, forKey: .tone)) ?? .direto
        emojis = (try? container.decodeIfPresent(Bool.self, forKey: .emojis)) ?? false
        extra = (try? container.decodeIfPresent(String.self, forKey: .extra)) ?? ""
    }
}

public struct AgentConfig: Codable, Sendable, Equatable {
    public var cwd: String
    public var model: String?
    public var claudePath: String?
    public var statusPrefix: String?
    /// A CLI `--permission-mode` value (`default`, `auto`, `bypassPermissions`); the bot reads it too.
    public var permissionMode: String?

    public init(
        cwd: String, model: String? = nil, claudePath: String? = nil, statusPrefix: String? = nil, permissionMode: String? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.claudePath = claudePath
        self.statusPrefix = statusPrefix
        self.permissionMode = permissionMode
    }
}

public struct AlertsBlock: Codable, Sendable, Equatable {
    public var list: String?
    public var resolve: String?
    public var discard: String?

    public init(list: String? = nil, resolve: String? = nil, discard: String? = nil) {
        self.list = list
        self.resolve = resolve
        self.discard = discard
    }
}

public struct TasksBlock: Codable, Sendable, Equatable {
    public var file: String?
    public var lock: String?

    public init(file: String? = nil, lock: String? = nil) {
        self.file = file
        self.lock = lock
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
    public var hooks: HooksBlock?
    public var commands: CommandsBlock?
    public var telegram: TelegramBlock?
    public var usage: UsageBlock?

    public init(
        alerts: AlertsBlock? = nil, tasks: TasksBlock? = nil, agenda: AgendaBlock? = nil,
        memory: MemoryBlock? = nil, routines: RoutinesBlock? = nil, telegram: TelegramBlock? = nil,
        usage: UsageBlock? = nil, hooks: HooksBlock? = nil, commands: CommandsBlock? = nil
    ) {
        self.alerts = alerts
        self.tasks = tasks
        self.agenda = agenda
        self.memory = memory
        self.routines = routines
        self.telegram = telegram
        self.usage = usage
        self.hooks = hooks
        self.commands = commands
    }
}

public struct Profile: Codable, Sendable, Equatable {
    public var persona: Persona
    public var agent: AgentConfig
    public var blocks: ProfileBlocks?
    public var soul: Soul

    public init(persona: Persona, agent: AgentConfig, blocks: ProfileBlocks? = nil, soul: Soul = Soul()) {
        self.persona = persona
        self.agent = agent
        self.blocks = blocks
        self.soul = soul
    }

    private enum CodingKeys: String, CodingKey {
        case persona, agent, blocks, soul
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        persona = try container.decode(Persona.self, forKey: .persona)
        agent = try container.decode(AgentConfig.self, forKey: .agent)
        blocks = try? container.decodeIfPresent(ProfileBlocks.self, forKey: .blocks)
        soul = (try? container.decodeIfPresent(Soul.self, forKey: .soul)) ?? Soul()
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
