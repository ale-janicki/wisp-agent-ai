import Foundation

public struct HooksBlock: Codable, Sendable, Equatable {
    public var list: String?
    public var disable: String?
    public var enable: String?

    public init(list: String? = nil, disable: String? = nil, enable: String? = nil) {
        self.list = list
        self.disable = disable
        self.enable = enable
    }
}

public struct CommandsBlock: Codable, Sendable, Equatable {
    public var dirs: [String]?

    public init(dirs: [String]? = nil) {
        self.dirs = dirs
    }
}

public struct HookEntry: Decodable, Identifiable, Equatable, Sendable {
    public var id: String
    public var event: String
    public var matcher: String?
    public var command: String
    public var script: String?
    public var summary: String?
    public var enabled: Bool
    public var locked: Bool
    public var missing: Bool

    public init(
        id: String, event: String, matcher: String? = nil, command: String, script: String? = nil,
        summary: String? = nil, enabled: Bool = true, locked: Bool = false, missing: Bool = false
    ) {
        self.id = id
        self.event = event
        self.matcher = matcher
        self.command = command
        self.script = script
        self.summary = summary
        self.enabled = enabled
        self.locked = locked
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey { case id, event, matcher, command, script, summary, enabled, locked, missing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        event = try c.decode(String.self, forKey: .event)
        matcher = Self.clean(try c.decodeIfPresent(String.self, forKey: .matcher))
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        script = Self.clean(try c.decodeIfPresent(String.self, forKey: .script))
        summary = Self.clean(try c.decodeIfPresent(String.self, forKey: .summary))
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        missing = try c.decodeIfPresent(Bool.self, forKey: .missing) ?? false
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public static let titleLimit = 60

    public var title: String {
        if let script { return script }
        let flat = command.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > Self.titleLimit ? String(flat.prefix(Self.titleLimit - 1)) + "…" : flat
    }

    public var detail: String? {
        let parts = [summary, matcher].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct HookOrphan: Decodable, Equatable, Sendable {
    public var script: String
    public var summary: String?

    public init(script: String, summary: String? = nil) {
        self.script = script
        self.summary = summary
    }
}

public struct HookGroup: Equatable, Sendable, Identifiable {
    public var event: String
    public var title: String
    public var hooks: [HookEntry]
    public var id: String { event }
}

public enum HooksReportError: Error, Equatable, LocalizedError {
    case invalid

    public var errorDescription: String? {
        "a lista de hooks não está no formato {\"hooks\": [...], \"orphans\": [...]}"
    }
}

public struct HooksReport: Decodable, Equatable, Sendable {
    public var hooks: [HookEntry]
    public var orphans: [HookOrphan]

    public init(hooks: [HookEntry] = [], orphans: [HookOrphan] = []) {
        self.hooks = hooks
        self.orphans = orphans
    }

    private enum CodingKeys: String, CodingKey { case hooks, orphans }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try c.decode([HookEntry].self, forKey: .hooks)
        orphans = try c.decodeIfPresent([HookOrphan].self, forKey: .orphans) ?? []
    }

    public static func parse(_ data: Data) throws -> HooksReport {
        do {
            return try JSONDecoder().decode(HooksReport.self, from: data)
        } catch {
            throw HooksReportError.invalid
        }
    }

    public static let eventTitles: [(event: String, title: String)] = [
        ("SessionStart", "Início da sessão"),
        ("UserPromptSubmit", "Ao enviar mensagem"),
        ("PreToolUse", "Antes de cada ferramenta"),
        ("PostToolUse", "Depois de cada ferramenta"),
        ("Stop", "Fim do turno"),
        ("SessionEnd", "Fim da sessão"),
    ]

    /// Known events in lifecycle order, then unknown ones in first-seen order under their raw name.
    public var groups: [HookGroup] {
        var order = Self.eventTitles.map(\.event)
        for hook in hooks where !order.contains(hook.event) { order.append(hook.event) }
        return order.compactMap { event in
            let members = hooks.filter { $0.event == event }
            guard !members.isEmpty else { return nil }
            let title = Self.eventTitles.first { $0.event == event }?.title ?? event
            return HookGroup(event: event, title: title, hooks: members)
        }
    }
}

public enum HookCommand {
    public static func build(_ template: String, id: String) -> String {
        template.replacingOccurrences(of: "{id}", with: MemorySearch.shellQuote(id))
    }
}

public struct CommandEntry: Identifiable, Equatable, Sendable {
    public var name: String
    public var detail: String?
    public var path: String
    public var id: String { path }
}

public enum CommandScanner {
    public static func scan(dirs: [String]) -> [CommandEntry] {
        let fm = FileManager.default
        var entries: [CommandEntry] = []
        for dir in dirs {
            let directory = expandTilde(dir)
            for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                guard (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      fm.isExecutableFile(atPath: path)
                else { continue }
                entries.append(CommandEntry(name: name, detail: firstComment(atPath: path), path: path))
            }
        }
        return entries.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
    }

    public static func firstComment(atPath path: String, maxBytes: Int = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.contains(0) else { return nil }
        return firstComment(in: String(decoding: data, as: UTF8.self))
    }

    public static func firstComment(in text: String) -> String? {
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0, line.hasPrefix("#!") { continue }
            if line.isEmpty { continue }
            guard line.hasPrefix("#") else { return nil }
            let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return body }
        }
        return nil
    }
}
