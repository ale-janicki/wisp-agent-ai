import XCTest
@testable import WispCore

/// The shell scripts, run by the real shells on a real pty with a scratch HOME: what they emit, and that the user's own files still
/// run and the environment is left as the user had it.
final class TerminalShellIntegrationTests: XCTestCase {
    private var home: URL!

    private static let scripts: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("app/Resources/ShellIntegration")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to name: String, in directory: URL? = nil) throws {
        let url = (directory ?? home).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The marks of a run, as short names, with the commands the shell reported.
    private struct Run {
        var output: String
        var events: [ShellEvent]
        var nonce: String

        var marks: [String] {
            events.compactMap { event in
                switch event {
                case .promptStart: "A"
                case .commandStart: "C"
                case .commandEnd(let code): "D\(code.map(String.init) ?? "-")"
                default: nil
                }
            }
        }

        var commands: [String] { events.compactMap { if case .command(let text) = $0 { text } else { nil } } }
        var directories: [String] { events.compactMap { if case .directory(let text) = $0 { text } else { nil } } }
    }

    /// Starts the shell the way the terminal does, types each line once its prompt is up (the nonce's A mark, then `prompt`), and
    /// ends with `exit`.
    private func run(
        shell path: String, prompt: String, waitFor markBody: String = "A\u{07}", extraEnvironment: [String: String] = [:], lines: [String]
    ) throws -> Run {
        let shell = TerminalShell(path: path)
        var base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "BASH_SILENCE_DEPRECATION_WARNING": "1"]
        for (key, value) in extraEnvironment { base[key] = value }
        let env = TerminalEnvironment.build(base: base, shell: shell, home: home.path, user: "tester")
        let launch = ShellIntegration(directory: Self.scripts).launch(shell: shell, environment: env, enabled: true)
        XCTAssertTrue(launch.integrated)
        let nonce = try XCTUnwrap(launch.markNonce)
        let pty = try TestPTY(executable: shell.path, argv: [launch.execName] + launch.arguments, env: launch.environment, directory: home.path)
        let mark = "\u{1B}]6973;\(nonce);" + markBody
        var output = ""
        XCTAssertTrue(waitForPrompt(pty, after: 0, output: &output, mark: mark, prompt: prompt), "no prompt from \(path): \(output.debugDescription)")
        for line in lines {
            let start = output.utf8.count
            pty.write(line + "\n")
            XCTAssertTrue(waitForPrompt(pty, after: start, output: &output, mark: mark, prompt: prompt), "no prompt after \(line.debugDescription)")
        }
        pty.write("exit\n")
        output += pty.read(timeout: 5)
        _ = pty.waitForExit(timeout: 10)
        var scanner = ShellMarkScanner(nonce: nonce)
        return Run(output: output, events: scanner.scan(Array(output.utf8)[...]).map(\.event), nonce: nonce)
    }

    /// Reads until, after byte `start`, the prompt mark has come and the prompt was drawn after it.
    private func waitForPrompt(_ pty: TestPTY, after start: Int, output: inout String, mark: String, prompt: String) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let tail = String(decoding: Array(output.utf8).dropFirst(start), as: UTF8.self)
            if let range = tail.range(of: mark, options: .backwards), tail[range.upperBound...].contains(prompt) { return true }
            output += pty.read(until: prompt, timeout: 0.5)
        } while Date() < deadline
        return false
    }

    private func assertTrueFalse(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
        let first = ["A", "C", "D0", "A", "C", "D1", "A"]
        XCTAssertEqual(Array(run.marks.prefix(first.count)), first, run.output.debugDescription, file: file, line: line)
        XCTAssertEqual(Array(run.commands.prefix(2)), ["true", "false"], file: file, line: line)
        XCTAssertTrue(run.directories.first?.hasSuffix(home.lastPathComponent) ?? false, "\(run.directories)", file: file, line: line)
        XCTAssertTrue(run.directories.first?.hasPrefix("file://") ?? false, file: file, line: line)
    }

    /// No child of the shell sees the nonce: not by name, not by value.
    private static let nonceCheck = "echo \"E[$(/usr/bin/env | /usr/bin/grep -c WISP_MARK_NONCE)]\""

    private func assertNonceHidden(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(run.output.contains("E[0]"), run.output.debugDescription, file: file, line: line)
        let printed = run.output.replacingOccurrences(of: "\u{1B}]6973;\(run.nonce);", with: "")
        XCTAssertFalse(printed.contains(run.nonce), "the nonce shows up outside its marks", file: file, line: line)
    }

    // MARK: zsh

    func testZshEmitsTheMarksSourcesTheUsersFilesAndRestoresZdotdir() throws {
        try write("export WISP_TEST_ENV=from_zshenv\n", to: ".zshenv")
        try write("export WISP_TEST_PROFILE=from_zprofile\n", to: ".zprofile")
        try write("export WISP_TEST_VAR=from_user_rc\nPS1='%# '\n", to: ".zshrc")
        try write("export WISP_TEST_LOGIN=from_zlogin\n", to: ".zlogin")
        let result = try run(shell: "/bin/zsh", prompt: "% ", lines: [
            "true", "false",
            "print -r -- \"V[$WISP_TEST_ENV|$WISP_TEST_PROFILE|$WISP_TEST_VAR|$WISP_TEST_LOGIN]\"",
            "print -r -- \"Z[${ZDOTDIR-unset}][${WISP_ZDOTDIR-unset}][${WISP_ORIG_ZDOTDIR-unset}]\"",
            "print -r -- \"H[$HISTFILE]\"",
            "/usr/bin/env | /usr/bin/grep -c '^ZDOTDIR='; echo",
            Self.nonceCheck,
            "print -r -- \"S[${WISP_MARK_NONCE-unset}][${parameters[_wisp_nonce]}]\"",
        ])
        assertTrueFalse(result)
        assertNonceHidden(result)
        XCTAssertTrue(result.output.contains("S[unset][scalar]"), "kept in the shell, never exported: \(result.output.debugDescription)")
        XCTAssertTrue(result.output.contains("V[from_zshenv|from_zprofile|from_user_rc|from_zlogin]"), result.output.debugDescription)
        XCTAssertTrue(result.output.contains("Z[unset][unset][unset]"), "children must see no ZDOTDIR: \(result.output.debugDescription)")
        XCTAssertTrue(result.output.contains("H[\(home.path)/.zsh_history]") || result.output.contains("H[]"), result.output.debugDescription)
        XCTAssertFalse(result.output.contains(Self.scripts.path + "/zsh/.zsh_history"))
    }

    func testZshKeepsTheUsersOwnZdotdir() throws {
        let custom = home.appendingPathComponent("custom-zsh")
        try write("export WISP_TEST_VAR=from_custom_rc\nPS1='%# '\n", to: ".zshrc", in: custom)
        let result = try run(shell: "/bin/zsh", prompt: "% ", extraEnvironment: ["ZDOTDIR": custom.path], lines: [
            "true", "false",
            "print -r -- \"V[$WISP_TEST_VAR]\"",
            "print -r -- \"Z[${ZDOTDIR-unset}]\"",
        ])
        assertTrueFalse(result)
        XCTAssertTrue(result.output.contains("V[from_custom_rc]"), result.output.debugDescription)
        XCTAssertTrue(result.output.contains("Z[\(custom.path)]"), result.output.debugDescription)
    }

    func testZshSendsTheTextOfEachCommand() throws {
        try write("PS1='%# '\n", to: ".zshrc")
        let result = try run(shell: "/bin/zsh", prompt: "% ", lines: ["echo 'ação com espaço'", "ls /nonexistent-wisp-dir"])
        XCTAssertEqual(Array(result.commands.prefix(2)), ["echo 'ação com espaço'", "ls /nonexistent-wisp-dir"])
        XCTAssertTrue(result.marks.contains("D1") || result.marks.contains("D2"), "\(result.marks)")
    }

    func testZshCtrlLAtThePromptClearsWithoutANewPromptMark() throws {
        try write("PS1='%# '\n", to: ".zshrc")
        let shell = TerminalShell(path: "/bin/zsh")
        let env = TerminalEnvironment.build(base: ["PATH": "/usr/bin:/bin"], shell: shell, home: home.path, user: "tester")
        let launch = ShellIntegration(directory: Self.scripts).launch(shell: shell, environment: env, enabled: true)
        let nonce = try XCTUnwrap(launch.markNonce)
        let pty = try TestPTY(executable: shell.path, argv: [launch.execName] + launch.arguments, env: launch.environment, directory: home.path)
        let mark = "\u{1B}]6973;\(nonce);A\u{07}"
        var output = ""
        XCTAssertTrue(waitForPrompt(pty, after: 0, output: &output, mark: mark, prompt: "% "))
        pty.write("\u{0C}")
        output += pty.read(until: "\u{1B}[2J", timeout: 5)
        let start = output.utf8.count
        pty.write("true\n")
        XCTAssertTrue(waitForPrompt(pty, after: start, output: &output, mark: mark, prompt: "% "))
        pty.write("exit\n")
        output += pty.read(timeout: 5)
        XCTAssertEqual(pty.waitForExit(timeout: 10), 0)
        var scanner = ShellMarkScanner(nonce: nonce)
        let events = scanner.scan(Array(output.utf8)[...]).map(\.event).filter {
            switch $0 {
            case .promptStart, .commandStart, .cleared, .command: true
            default: false
            }
        }
        XCTAssertEqual(
            Array(events.prefix(5)), [.promptStart, .cleared(scrollback: false), .command("true"), .commandStart, .promptStart],
            output.debugDescription)
        // What the tracker does with exactly that order is `BlockTrackerTests.testClearingAtThePromptKeepsItSoTheNextCommandIsABlock`.
    }

    // MARK: Paste again

    /// vi command mode takes typed letters as commands, and Ctrl-E Ctrl-U do not empty its line: the paste must run nothing.
    private func assertPasteAgainRunsNothingInViMode(
        shell path: String, rc: String, rcName: String, prompt: String, bracketedPaste: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try write(rc, to: rcName)
        let shell = TerminalShell(path: path)
        let env = TerminalEnvironment.build(
            base: ["PATH": "/usr/bin:/bin", "BASH_SILENCE_DEPRECATION_WARNING": "1"], shell: shell, home: home.path, user: "tester")
        let launch = ShellIntegration(directory: Self.scripts).launch(shell: shell, environment: env, enabled: true)
        let nonce = try XCTUnwrap(launch.markNonce)
        let pty = try TestPTY(executable: shell.path, argv: [launch.execName] + launch.arguments, env: launch.environment, directory: home.path)
        var output = ""
        XCTAssertTrue(waitForPrompt(pty, after: 0, output: &output, mark: "\u{1B}]6973;\(nonce);A\u{07}", prompt: prompt), file: file, line: line)
        pty.write("echo DANGER\u{1B}")
        output += pty.read(timeout: 0.5)
        let start = output.utf8.count
        switch try BlockRerun.decide(command: "echo safe", bracketedPaste: bracketedPaste, atPrompt: true).get() {
        case .type(let bytes):
            XCTAssertTrue(bracketedPaste, file: file, line: line)
            pty.write(String(decoding: bytes, as: UTF8.self))
        case .copy(let text):
            XCTAssertFalse(bracketedPaste, file: file, line: line)
            XCTAssertEqual(text, "echo safe", "copied, nothing typed", file: file, line: line)
        }
        output += pty.read(timeout: 1.5)
        let after = String(decoding: Array(output.utf8).dropFirst(start), as: UTF8.self)
        var scanner = ShellMarkScanner(nonce: nonce)
        let ran = scanner.scan(Array(after.utf8)[...]).map(\.event).filter {
            if case .command = $0 { return true }
            return $0 == .commandStart
        }
        XCTAssertEqual(ran, [], "the paste ran something: \(after.debugDescription)", file: file, line: line)
        XCTAssertFalse(after.contains("DANGER\r\n"), after.debugDescription, file: file, line: line)
        // The line is left as it is: the pty's owner kills the shell when it goes.
    }

    func testZshPasteAgainInViCommandModeRunsNothing() throws {
        try assertPasteAgainRunsNothingInViMode(
            shell: "/bin/zsh", rc: "PS1='%# '\nbindkey -v\n", rcName: ".zshrc", prompt: "% ", bracketedPaste: true)
        try assertPasteAgainRunsNothingInViMode(
            shell: "/bin/zsh", rc: "PS1='%# '\nbindkey -v\n", rcName: ".zshrc", prompt: "% ", bracketedPaste: false)
    }

    func testBashPasteAgainInViCommandModeRunsNothing() throws {
        try assertPasteAgainRunsNothingInViMode(
            shell: "/bin/bash", rc: "PS1='$ '\nset -o vi\n", rcName: ".bash_profile", prompt: "$ ", bracketedPaste: false)
    }

    // MARK: bash

    func testBashWithItsOwnDebugTrapDeclinesAndStillReportsTheFolder() throws {
        try write("PS1='$ '\ntrap 'true' DEBUG\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", waitFor: "cwd=", lines: ["cd /tmp", "trap -p DEBUG", "true"])
        XCTAssertEqual(result.events.first, .declined, result.output.debugDescription)
        XCTAssertEqual(result.marks, [], "no blocks")
        XCTAssertTrue(result.directories.first?.hasSuffix(home.lastPathComponent) ?? false, "\(result.directories)")
        XCTAssertTrue(result.directories.last?.hasSuffix("/tmp") ?? false, "\(result.directories)")
        XCTAssertTrue(result.output.contains("trap -- 'true' DEBUG"), "the user's trap is left as it was: \(result.output.debugDescription)")
    }

    func testBashEmitsTheMarksAndSourcesTheLoginProfile() throws {
        try write("export WISP_TEST_VAR=from_bash_profile\nPS1='$ '\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: [
            "true", "false", "echo \"V[$WISP_TEST_VAR]\"", Self.nonceCheck, "echo \"S[${WISP_MARK_NONCE-unset}]\"",
        ])
        assertTrueFalse(result)
        assertNonceHidden(result)
        XCTAssertTrue(result.output.contains("V[from_bash_profile]"), result.output.debugDescription)
        XCTAssertTrue(result.output.contains("S[unset]"), result.output.debugDescription)
    }

    func testBashRecordsTheWholeLineTyped() throws {
        try write("PS1='$ '\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: ["echo a | cat", "cd /tmp && true", "echo x; echo y"])
        XCTAssertEqual(result.commands, ["echo a | cat", "cd /tmp && true", "echo x; echo y", "exit"], result.output.debugDescription)
        XCTAssertEqual(result.marks, ["A", "C", "D0", "A", "C", "D0", "A", "C", "D0", "A", "C"], "one block per line typed (the last is exit)")
    }

    func testBashAnEmptyEnterOrCtrlCAtThePromptIsNoCommand() throws {
        try write("PS1='$ '\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: ["", "", "\u{03}", "true"])
        XCTAssertEqual(result.commands, ["true", "exit"], result.output.debugDescription)
        XCTAssertEqual(result.marks.filter { $0 != "A" }, ["C", "D0", "C"], "\(result.marks)")
    }

    func testBashForgedMarksFromOutputCount() throws {
        try write("PS1='$ '\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: [
            "printf '\\e]133;A\\a\\e]6973;A\\a\\e]6973;0123456789abcdef0123456789abcdef;C\\a\\e]6973;;D;0\\a'; echo",
        ])
        XCTAssertEqual(result.marks, ["A", "C", "D0", "A", "C"], "only the shell's own marks (the last C is exit): \(result.output.debugDescription)")
    }

    func testBashUserPromptCommandSeesTheRealStatus() throws {
        try write("PS1='$ '\nPROMPT_COMMAND='echo \"PC:$?\"'\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: ["false", "true"])
        XCTAssertTrue(result.output.contains("PC:1"), result.output.debugDescription)
        XCTAssertEqual(Array(result.marks.prefix(4)), ["A", "C", "D1", "A"])
    }

    func testBashExportedPromptCommandDoesNotLeakIntoANestedShell() throws {
        try write("PS1='$ '\nexport PROMPT_COMMAND='export WISP_TEST_PC=ran'\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: [
            "/bin/bash --norc -i\necho \"NESTED[$WISP_TEST_PC]\"\nexit", "echo \"PC[$WISP_TEST_PC]\"",
        ])
        XCTAssertFalse(result.output.contains("command not found"), result.output.debugDescription)
        XCTAssertTrue(result.output.contains("PC[ran]"), "the user's PROMPT_COMMAND still runs: \(result.output.debugDescription)")
    }

    func testBashPercentEncodesANonASCIIDirectory() throws {
        let path = "/tmp/dír ç/a b"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/dír ç") }
        try write("PS1='$ '\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: ["cd '\(path)'"])
        XCTAssertTrue(
            result.directories.last?.hasSuffix("/tmp/d%C3%ADr%20%C3%A7/a%20b") ?? false, "\(result.directories)")
    }

    func testBashSendsTheTextOfEachCommandAndSurvivesAUserPromptCommand() throws {
        try write("PS1='$ '\nPROMPT_COMMAND='export WISP_TEST_PC=ran'\n", to: ".bash_profile")
        let result = try run(shell: "/bin/bash", prompt: "$ ", lines: ["echo one two", "echo \"PC[$WISP_TEST_PC]\""])
        XCTAssertEqual(Array(result.commands.prefix(2)), ["echo one two", "echo \"PC[$WISP_TEST_PC]\""])
        XCTAssertTrue(result.output.contains("PC[ran]"), result.output.debugDescription)
    }

    // MARK: fish

    func testFishEmitsTheMarksAndPutsXdgDataDirsBack() throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("fish is not installed on this machine")
        }
        try write("set -gx WISP_TEST_VAR from_fish_config\n", to: ".config/fish/config.fish")
        let result = try run(shell: fish, prompt: "> ", lines: ["true", "false", "echo \"V[$WISP_TEST_VAR][$XDG_DATA_DIRS]\"", Self.nonceCheck])
        assertTrueFalse(result)
        assertNonceHidden(result)
        XCTAssertTrue(result.output.contains("V[from_fish_config]["), result.output.debugDescription)
        XCTAssertFalse(result.output.contains(Self.scripts.path), "XDG_DATA_DIRS must not keep the Wisp directory")
    }
}
