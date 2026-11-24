import XCTest
@testable import WispCore

final class TerminalEnvironmentTests: XCTestCase {
    private let zsh = TerminalShell(path: "/bin/zsh")

    func testSetsTheTerminalIdentity() {
        let env = TerminalEnvironment.build(base: [:], shell: zsh, home: "/home/dev", user: "a", version: "0.4.10")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["TERM_PROGRAM"], "Wisp")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], "0.4.10")
        XCTAssertEqual(env["SHELL"], "/bin/zsh")
        XCTAssertEqual(env["HOME"], "/home/dev")
        XCTAssertEqual(env["USER"], "a")
        XCTAssertEqual(env["LOGNAME"], "a")
    }

    func testLangComesFromTheEnvironmentOrDefaults() {
        XCTAssertEqual(TerminalEnvironment.build(base: ["LANG": "pt_BR.UTF-8"], shell: zsh, home: "/h", user: "u")["LANG"], "pt_BR.UTF-8")
        XCTAssertEqual(TerminalEnvironment.build(base: [:], shell: zsh, home: "/h", user: "u")["LANG"], "en_US.UTF-8")
        XCTAssertEqual(TerminalEnvironment.build(base: ["LANG": ""], shell: zsh, home: "/h", user: "u")["LANG"], "en_US.UTF-8")
    }

    func testOverridesAnInheritedTerminalIdentity() {
        let base = ["TERM": "dumb", "TERM_PROGRAM": "Apple_Terminal", "TERM_PROGRAM_VERSION": "9", "SHELL": "/bin/sh"]
        let env = TerminalEnvironment.build(base: base, shell: zsh, home: "/h", user: "u")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["TERM_PROGRAM"], "Wisp")
        XCTAssertNil(env["TERM_PROGRAM_VERSION"])
        XCTAssertEqual(env["SHELL"], "/bin/zsh")
    }

    func testKeepsPathAndUserVariablesButDropsClaudeAccountOnes() {
        let base = [
            "PATH": "/usr/bin:/bin", "EDITOR": "vim", "USER": "kept",
            "ANTHROPIC_API_KEY": "x", "CLAUDE_CONFIG_DIR": "/x", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "COLUMNS": "10", "LINES": "5",
        ]
        let env = TerminalEnvironment.build(base: base, shell: zsh, home: "/h", user: "u")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["EDITOR"], "vim")
        XCTAssertEqual(env["USER"], "kept")
        for dropped in ["ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "COLUMNS", "LINES"] {
            XCTAssertNil(env[dropped], dropped)
        }
    }

    func testDropsTheRuntimeAndEngineVariables() {
        let base = [
            "WISP_RESOURCES": "/x", "WISP_CONFIG": "/y", "UV_PYTHON": "3", "UV_CACHE_DIR": "/c", "PYTHONPATH": "/p",
            "OPENAI_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t", "CODEX_HOME": "/h", "CODEX_API_KEY": "k",
            "PYTHONHOME": "kept", "WISPY": "kept", "UVX": "kept", "OPENAI_ORG": "kept",
        ]
        let env = TerminalEnvironment.build(base: base, shell: zsh, home: "/h", user: "u")
        for dropped in ["WISP_RESOURCES", "WISP_CONFIG", "UV_PYTHON", "UV_CACHE_DIR", "PYTHONPATH", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CODEX_HOME", "CODEX_API_KEY"] {
            XCTAssertNil(env[dropped], dropped)
        }
        for kept in ["PYTHONHOME", "WISPY", "UVX", "OPENAI_ORG"] {
            XCTAssertEqual(env[kept], "kept", kept)
        }
    }

    func testRuntimeEnvironmentKeepsEverythingButTheInterpreterOverrides() {
        let env = RuntimeEnvironment.forRuntime(["UV_X": "1", "PYTHONPATH": "/p", "PATH": "/bin", "ANTHROPIC_API_KEY": "k", "WISP_X": "w"])
        XCTAssertEqual(env, ["PATH": "/bin", "ANTHROPIC_API_KEY": "k", "WISP_X": "w"])
    }

    func testLinesAreSortedKeyValuePairs() {
        XCTAssertEqual(TerminalEnvironment.lines(["B": "2", "A": "1=x"]), ["A=1=x", "B=2"])
    }
}
