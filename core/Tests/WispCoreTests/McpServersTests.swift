import Foundation
import Testing
@testable import WispCore

@Suite struct McpServersTests {
    private func makeHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func claudeUserAndProjectServersNeverSurfaceSecrets() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = home + "/work"
        try write("""
        {"mcpServers": {
           "wisp-email": {"command": "/x/venv/bin/wisp", "args": ["mcp", "email"]},
           "wisp-brain": {"command": "/bin/other", "args": []},
           "db": {"type": "stdio", "command": "/usr/local/bin/npx", "args": ["--token=ARGSECRET"], "env": {"API_KEY": "ENVSECRET"}},
           "remote": {"type": "http", "url": "https://mcp.example.com/v1?key=URLSECRET", "headers": {"Authorization": "Bearer HEADSECRET"}},
           "off": {"command": "node", "disabled": true},
           "junk": "text"},
         "projects": {"\(cwd)": {"mcpServers": {"proj": {"command": "uvx"}}, "disabledMcpServers": ["proj"]}}}
        """, to: home + "/.claude.json")
        let found = McpServers.claude(home: home, cwd: cwd)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["wisp-email", "wisp-brain", "db", "remote", "off", "proj"])
        #expect(byName["db"]?.transport == "stdio · npx")
        #expect(byName["remote"]?.transport == "http · mcp.example.com")
        #expect(byName["wisp-email"]?.installedByWisp == true)
        #expect(byName["wisp-brain"]?.installedByWisp == false)
        #expect(byName["off"]?.disabled == true)
        #expect(byName["proj"]?.scope == .project)
        #expect(byName["proj"]?.disabled == true)
        #expect(byName["db"]?.scope == .user)

        let dump = String(describing: found)
        for secret in ["ENVSECRET", "ARGSECRET", "URLSECRET", "HEADSECRET", "API_KEY", "Bearer"] {
            #expect(!dump.contains(secret), "\(secret) leaked")
        }
    }

    @Test func claudeReadsMcpJsonAndPlugins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = home + "/work"
        try write(#"{"mcpServers": {"local-tool": {"command": "bun"}}}"#, to: cwd + "/.mcp.json")
        let plugin = home + "/.claude/plugins/cache/p/1"
        try write(#"{"plugins": {"p@m": [{"installPath": "\#(plugin)"}], "q@m": [{"installPath": "\#(home)/none"}]}}"#,
                  to: home + "/.claude/plugins/installed_plugins.json")
        try write(#"{"plug-server": {"type": "sse", "url": "https://sse.example.org:8443/x"}}"#, to: plugin + "/.mcp.json")
        let found = McpServers.claude(home: home, cwd: cwd)

        #expect(found.contains { $0.name == "local-tool" && $0.scope == .project && $0.transport == "stdio · bun" })
        #expect(found.contains { $0.name == "plug-server" && $0.scope == .plugin && $0.transport == "sse · sse.example.org" })
    }

    @Test func disabledPluginIsSkipped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let plugin = home + "/.claude/plugins/cache/p/1"
        try write(#"{"plugins": {"p@m": [{"installPath": "\#(plugin)"}]}}"#, to: home + "/.claude/plugins/installed_plugins.json")
        try write(#"{"enabledPlugins": {"p@m": false}}"#, to: home + "/.claude/settings.json")
        try write(#"{"mcpServers": {"s": {"command": "x"}}}"#, to: plugin + "/.mcp.json")
        #expect(McpServers.claude(home: home, cwd: home).isEmpty)
    }

    @Test func missingConfigIsEmpty() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(McpServers.claude(home: home, cwd: home).isEmpty)
        #expect(McpServers.codex(home: home).isEmpty)
    }

    @Test func codexTablesIgnoreSubTablesAndSecrets() {
        let toml = """
        model = "gpt"
        [mcp_servers.docs]
        command = "/opt/bin/docs-server"
        args = ["--key", "ARGSECRET"]
        enabled_tools = ["false"]

        [mcp_servers.docs.env]
        TOKEN = "ENVSECRET"

        [mcp_servers.web]
        url = "https://api.example.com/mcp"
        http_headers = { Authorization = "HEADSECRET" }
        enabled = false

        [mcp_servers."quoted.name"]
        command = "wisp"

        [other]
        command = "nope"
        """
        let found = McpServers.parseCodex(toml)
        #expect(found.map(\.name) == ["docs", "web", "quoted.name"])
        #expect(found[0].transport == "stdio · docs-server")
        #expect(found[0].disabled == false)
        #expect(found[1].transport == "http · api.example.com")
        #expect(found[1].disabled == true)
        let dump = String(describing: found)
        for secret in ["ARGSECRET", "ENVSECRET", "HEADSECRET", "TOKEN"] { #expect(!dump.contains(secret)) }
    }

    @Test func localListsBuiltInsAndToolFiles() throws {
        let dir = URL(fileURLWithPath: try makeHome())
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("name = \"notes\"\ncommand = \"/bin/notes-mcp\"\nargs = [\"--x\"]\n[env]\nK = \"ENVSECRET\"\n",
                  to: dir.path + "/ferramentas/notes.toml")
        try write("name = \"wisp-email\"\ncommand = \"evil\"\n", to: dir.path + "/ferramentas/dup.toml")
        let found = McpServers.local(wispDir: dir)
        #expect(found.map(\.name) == ["wisp-email", "wisp-brain", "notes"])
        #expect(found[0].installedByWisp && found[0].scope == .wisp)
        #expect(found[2].transport == "stdio · notes-mcp" && !found[2].installedByWisp)
        #expect(!String(describing: found).contains("ENVSECRET"))
    }

    @Test func pluginOutsidePluginsFolderIsIgnored() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(#"{"plugins": {"p@m": [{"installPath": "\#(home)/elsewhere"}]}}"#, to: home + "/.claude/plugins/installed_plugins.json")
        try write(#"{"mcpServers": {"s": {"command": "x"}}}"#, to: home + "/elsewhere/.mcp.json")
        #expect(McpServers.claude(home: home, cwd: home).isEmpty)
    }

    @Test func mcpJsonWalkStopsAtHome() {
        #expect(McpServers.mcpJsonFolders(cwd: "/h/u/a/b", home: "/h/u") == ["/h/u/a/b", "/h/u/a", "/h/u"])
        #expect(McpServers.mcpJsonFolders(cwd: "/h/u", home: "/h/u") == ["/h/u"])
        #expect(McpServers.mcpJsonFolders(cwd: "/tmp/x/y", home: "/h/u") == ["/tmp/x/y"])
        #expect(McpServers.mcpJsonFolders(cwd: "/h/u2/x", home: "/h/u") == ["/h/u2/x"])
    }

    @Test func mcpJsonOutsideHomeOrAboveItIsNotRead() throws {
        let base = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let home = base + "/home"
        // above home: must not be read
        try write(#"{"mcpServers": {"above": {"command": "x"}}}"#, to: base + "/.mcp.json")
        try write(#"{"mcpServers": {"at-home": {"command": "x"}}}"#, to: home + "/.mcp.json")
        try write(#"{"mcpServers": {"deep": {"command": "x"}}}"#, to: home + "/a/b/.mcp.json")
        let inside = Set(McpServers.claude(home: home, cwd: home + "/a/b").map(\.name))
        #expect(inside == ["deep", "at-home"])
        // cwd outside home: only itself
        try write(#"{"mcpServers": {"outside": {"command": "x"}}}"#, to: base + "/other/sub/.mcp.json")
        try write(#"{"mcpServers": {"parent": {"command": "x"}}}"#, to: base + "/other/.mcp.json")
        #expect(Set(McpServers.claude(home: home, cwd: base + "/other/sub").map(\.name)) == ["outside"])
    }

    @Test func sameNameInTwoSourcesKeepsOneByPrecedence() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = home + "/w"
        try write("""
        {"mcpServers": {"dup": {"command": "user-cmd"}, "only-user": {"command": "u"}},
         "projects": {"\(cwd)": {"mcpServers": {"dup": {"command": "proj-cmd"}}}}}
        """, to: home + "/.claude.json")
        try write(#"{"mcpServers": {"dup": {"command": "file-cmd"}, "dup2": {"command": "a"}}}"#, to: cwd + "/.mcp.json")
        try write(#"{"mcpServers": {"dup2": {"command": "home-cmd"}}}"#, to: home + "/.mcp.json")
        let found = McpServers.claude(home: home, cwd: cwd)
        #expect(found.map(\.name).sorted() == ["dup", "dup2", "only-user"])
        #expect(found.first { $0.name == "dup" }?.transport == "stdio · proj-cmd")
        #expect(found.first { $0.name == "dup2" }?.transport == "stdio · a")
        #expect(Set(found.map(\.id)).count == found.count)
    }

    @Test func oversizedConfigIsSkipped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let filler = String(repeating: "x", count: McpServers.fileLimit + 10)
        try write(#"{"mcpServers": {"s": {"command": "x"}}, "pad": "\#(filler)"}"#, to: home + "/w/.mcp.json")
        #expect(McpServers.claude(home: home, cwd: home + "/w").isEmpty)
    }
}
