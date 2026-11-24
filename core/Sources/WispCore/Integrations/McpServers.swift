import Foundation

public enum McpScope: String, Sendable, Equatable {
    case user = "usuário"
    case project = "projeto"
    case plugin
    case wisp = "Wisp"
}

/// What the Settings pane may show about one MCP server. It never holds env values, headers, tokens or args:
/// the parsers below read only the name, the transport kind, the command basename or URL host, and the disabled flag.
public struct McpServerInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var transport: String
    public var scope: McpScope
    public var installedByWisp: Bool
    public var disabled: Bool

    public var id: String { "\(scope.rawValue)/\(name)" }

    public init(name: String, transport: String, scope: McpScope, installedByWisp: Bool = false, disabled: Bool = false) {
        self.name = name
        self.transport = transport
        self.scope = scope
        self.installedByWisp = installedByWisp
        self.disabled = disabled
    }
}

/// Reads the MCP servers an engine is configured with, from its config files. Nothing is started.
public enum McpServers {
    /// The servers the Wisp harness registers by name; a server with one of these names counts as ours only when its command is `wisp`.
    public static let wispServerNames: Set<String> = ["wisp-email", "wisp-brain", "wisp-mac"]
    /// The local engine always loads these two, and `ferramentas/*.toml` of the Wisp folder besides.
    public static let localBuiltIn = ["wisp-email", "wisp-brain"]
    /// Config files bigger than this are skipped; ~/.claude.json holds every project's history, so it gets more room.
    static let fileLimit = 5_000_000
    static let claudeConfigLimit = 50_000_000

    public static func scan(
        engine: EngineKind, home: String = NSHomeDirectory(), cwd: String, wispDir: URL = WispFolder.directory(),
        fileManager: FileManager = .default
    ) -> [McpServerInfo] {
        switch engine {
        case .claude: claude(home: home, cwd: cwd, fileManager: fileManager)
        case .codex: codex(home: home, fileManager: fileManager)
        case .local: local(wispDir: wispDir, fileManager: fileManager)
        }
    }

    // MARK: Claude

    /// Precedence when a name appears in several sources: project (~/.claude.json) > .mcp.json (nearest folder first) > user > plugin.
    public static func claude(home: String, cwd: String, fileManager: FileManager = .default) -> [McpServerInfo] {
        let root = jsonObject(at: home + "/.claude.json", fileManager, limit: claudeConfigLimit)
        let projectEntry = (root?["projects"] as? [String: Any])?[cwd] as? [String: Any]
        let disabledByProject = Set((projectEntry?["disabledMcpServers"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let disabledMcpJson = Set((projectEntry?["disabledMcpjsonServers"] as? [Any])?.compactMap { $0 as? String } ?? [])

        var found = servers(in: projectEntry?["mcpServers"], scope: .project)
        for directory in mcpJsonFolders(cwd: cwd, home: home) {
            let file = jsonObject(at: directory + "/.mcp.json", fileManager)
            found += servers(in: file?["mcpServers"] ?? file, scope: .project, disabledNames: disabledMcpJson)
        }
        found += servers(in: root?["mcpServers"], scope: .user)
        found += plugins(home: home, fileManager: fileManager)
        return unique(found).map { server in
            var server = server
            if server.scope != .plugin, disabledByProject.contains(server.name) { server.disabled = true }
            return server
        }
    }

    /// Keeps the first server of each name, so the order of the sources is the precedence.
    static func unique(_ list: [McpServerInfo]) -> [McpServerInfo] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.name).inserted }
    }

    private static func plugins(home: String, fileManager: FileManager) -> [McpServerInfo] {
        let installed = jsonObject(at: home + "/.claude/plugins/installed_plugins.json", fileManager)?["plugins"] as? [String: Any] ?? [:]
        let enabled = jsonObject(at: home + "/.claude/settings.json", fileManager)?["enabledPlugins"] as? [String: Any] ?? [:]
        let pluginsRoot = URL(fileURLWithPath: home + "/.claude/plugins").resolvingSymlinksInPath().path
        var found: [McpServerInfo] = []
        for id in installed.keys.sorted() where (enabled[id] as? Bool) != false {
            guard let installs = installed[id] as? [[String: Any]], let path = installs.first?["installPath"] as? String else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(pluginsRoot + "/") else { continue }
            let file = jsonObject(at: resolved + "/.mcp.json", fileManager)
            var pluginServers = servers(in: file?["mcpServers"] ?? file, scope: .plugin)
            if pluginServers.isEmpty {
                let manifest = jsonObject(at: resolved + "/.claude-plugin/plugin.json", fileManager)
                pluginServers = servers(in: manifest?["mcpServers"], scope: .plugin)
            }
            found += pluginServers
        }
        return found
    }

    /// `table` is a `{ name: { command | url, ... } }` object. Entries that are not objects are skipped.
    static func servers(in table: Any?, scope: McpScope, disabledNames: Set<String> = []) -> [McpServerInfo] {
        guard let table = table as? [String: Any] else { return [] }
        return table.keys.sorted().compactMap { name in
            guard let entry = table[name] as? [String: Any], entry["command"] is String || entry["url"] is String else { return nil }
            let command = entry["command"] as? String
            return McpServerInfo(
                name: name,
                transport: transport(type: entry["type"] as? String, command: command, url: entry["url"] as? String),
                scope: scope,
                installedByWisp: scope == .user && wispServerNames.contains(name) && command.map(basename) == "wisp",
                disabled: (entry["disabled"] as? Bool) == true || (entry["enabled"] as? Bool) == false || disabledNames.contains(name))
        }
    }

    // MARK: Codex

    public static func codex(home: String, fileManager: FileManager = .default) -> [McpServerInfo] {
        guard let data = readCapped(home + "/.codex/config.toml", fileManager, limit: fileLimit) else { return [] }
        return unique(parseCodex(String(decoding: data, as: UTF8.self)))
    }

    /// A minimal reader for the `[mcp_servers.<name>]` tables. Sub-tables (`.env`, `.http_headers`) are skipped on purpose,
    /// and only `command`, `url` and `enabled` are read from the table itself.
    public static func parseCodex(_ text: String) -> [McpServerInfo] {
        var found: [McpServerInfo] = []
        var current: (name: String, command: String?, url: String?, enabled: Bool)?
        func close() {
            guard let table = current, table.command != nil || table.url != nil else { return }
            found.append(McpServerInfo(
                name: table.name, transport: transport(type: nil, command: table.command, url: table.url), scope: .user,
                installedByWisp: wispServerNames.contains(table.name) && table.command.map(basename) == "wisp",
                disabled: !table.enabled))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                close()
                current = tableName(line).map { ($0, nil, nil, true) }
                continue
            }
            guard current != nil else { continue }
            if let value = codexString(line, key: "command") { current?.command = value }
            else if let value = codexString(line, key: "url") { current?.url = value }
            else if isFalse(line, key: "enabled") { current?.enabled = false }
        }
        close()
        return found
    }

    /// The server name of a `[mcp_servers.name]` header; nil for any other table, and for sub-tables of a server.
    static func tableName(_ header: String) -> String? {
        let prefix = "[mcp_servers."
        guard header.hasPrefix(prefix), let end = header.lastIndex(of: "]") else { return nil }
        let rest = String(header[header.index(header.startIndex, offsetBy: prefix.count)..<end]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            let name = String(rest.dropFirst().dropLast())
            return name.isEmpty || name.contains("\"") ? nil : name
        }
        return rest.isEmpty || rest.contains(".") ? nil : rest
    }

    private static func isFalse(_ line: String, key: String) -> Bool {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 && parts[0] == key && parts[1].hasPrefix("false")
    }

    private static func codexString(_ line: String, key: String) -> String? {
        EngineChoice.topLevelString(line, key: key)
    }

    // MARK: Local

    public static func local(wispDir: URL, fileManager: FileManager = .default) -> [McpServerInfo] {
        var found = localBuiltIn.map { McpServerInfo(name: $0, transport: "stdio · wisp", scope: .wisp, installedByWisp: true) }
        let folder = wispDir.appendingPathComponent("ferramentas")
        let files = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".toml") }.sorted()
        for file in files {
            guard let data = readCapped(folder.appendingPathComponent(file).path, fileManager, limit: fileLimit) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard let command = EngineChoice.topLevelString(text, key: "command") else { continue }
            let name = EngineChoice.topLevelString(text, key: "name") ?? String(file.dropLast(5))
            guard !localBuiltIn.contains(name) else { continue }
            found.append(McpServerInfo(name: name, transport: transport(type: nil, command: command, url: nil), scope: .wisp))
        }
        return unique(found)
    }

    // MARK: Shared

    static func transport(type: String?, command: String?, url: String?) -> String {
        if let url {
            let kind = type == "sse" ? "sse" : "http"
            let host = URLComponents(string: url)?.host ?? "?"
            return "\(kind) · \(host)"
        }
        return "stdio · \(command.map(basename) ?? "?")"
    }

    static func basename(_ command: String) -> String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }

    /// The cwd and its parents up to the home folder; a cwd outside home gets only itself. Never `/Users`, `/` or `/tmp`.
    static func mcpJsonFolders(cwd: String, home: String) -> [String] {
        let start = URL(fileURLWithPath: cwd).standardized.path
        let top = URL(fileURLWithPath: home).standardized.path
        guard start == top || start.hasPrefix(top + "/") else { return [start] }
        var result: [String] = []
        var current = start
        while true {
            result.append(current)
            if current == top { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return result
    }

    private static func readCapped(_ path: String, _ fileManager: FileManager, limit: Int) -> Data? {
        guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue <= limit else { return nil }
        return fileManager.contents(atPath: path)
    }

    private static func jsonObject(at path: String, _ fileManager: FileManager, limit: Int = fileLimit) -> [String: Any]? {
        guard let data = readCapped(path, fileManager, limit: limit) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
