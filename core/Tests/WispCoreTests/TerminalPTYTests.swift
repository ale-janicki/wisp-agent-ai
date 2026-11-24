import XCTest
@testable import WispCore

/// Real children on a real pty. The engine in the app (SwiftTerm's LocalProcess) is not reachable from the core package, so these
/// cover what the session asks of any engine: how the shell is started, the exit status, the PATH a login shell builds and the
/// window size the child sees.
final class TerminalPTYTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testOutputAndExitCode() throws {
        let pty = try TestPTY(executable: "/bin/sh", argv: ["sh", "-c", "printf ok; exit 3"], env: ["PATH": "/usr/bin:/bin"], directory: scratch.path)
        let output = pty.read(until: "ok")
        XCTAssertTrue(output.contains("ok"), output)
        XCTAssertEqual(pty.waitForExit(), 3)
    }

    func testChildSeesTheStartingSizeAndTheResize() throws {
        let script = "stty size; trap 'stty size; exit 0' WINCH; echo ready; while :; do sleep 0.1; done"
        let pty = try TestPTY(executable: "/bin/sh", argv: ["sh", "-c", script], env: ["PATH": "/usr/bin:/bin"], directory: scratch.path, columns: 100, rows: 30)
        let first = pty.read(until: "ready")
        XCTAssertTrue(first.contains("30 100"), first)
        pty.resize(columns: 132, rows: 41)
        let second = pty.read(until: "41 132")
        XCTAssertTrue(second.contains("41 132"), second)
        XCTAssertEqual(pty.waitForExit(), 0)
    }

    func testStartsInTheGivenDirectory() throws {
        let pty = try TestPTY(executable: "/bin/sh", argv: ["sh", "-c", "pwd -P"], env: ["PATH": "/usr/bin:/bin"], directory: scratch.path)
        let output = pty.read(until: scratch.lastPathComponent)
        XCTAssertTrue(output.contains(scratch.lastPathComponent), output)
    }

    /// The Finder case (0.4.6 and 0.4.7): the app's own environment is bare, and the login shell has to rebuild PATH from the
    /// user's profile files. The home is a scratch one with a `.zprofile`, so the result does not depend on this machine.
    func testLoginShellRebuildsPathFromABareEnvironment() throws {
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)

        let shell = TerminalShell(path: "/bin/zsh")
        let bare = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let env = TerminalEnvironment.build(base: bare, shell: shell, home: home.path, user: "tester")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "the session never invents a PATH")

        let marked = "printf 'PATH=%s\\n' \"$PATH\""
        let pty = try TestPTY(executable: shell.path, argv: [shell.loginName, "-c", marked], env: env, directory: home.path)
        let output = pty.read(until: "\n", timeout: 15)
        XCTAssertEqual(pty.waitForExit(), 0)
        XCTAssertTrue(output.contains("PATH=\(home.path)/.local/bin:"), output)
    }

    /// Without the leading dash the same shell is not a login shell and never reads `.zprofile`: the argv0 is what matters.
    func testNonLoginShellDoesNotRebuildPath() throws {
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "export PATH=\"$HOME/.local/bin:$PATH\"\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let env = TerminalEnvironment.build(base: ["PATH": "/usr/bin:/bin"], shell: TerminalShell(path: "/bin/zsh"), home: home.path, user: "tester")
        let pty = try TestPTY(executable: "/bin/zsh", argv: ["zsh", "-c", "printf 'PATH=%s\\n' \"$PATH\""], env: env, directory: home.path)
        let output = pty.read(until: "\n", timeout: 15)
        XCTAssertFalse(output.contains(".local/bin"), output)
    }

    func testRealLoginShellOfThisUserHasLocalBin() throws {
        let shell = TerminalShell.resolve(shellVariable: ProcessInfo.processInfo.environment["SHELL"])
        let home = NSHomeDirectory()
        let env = TerminalEnvironment.build(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], shell: shell, home: home, user: NSUserName())
        let pty = try TestPTY(executable: shell.path, argv: [shell.loginName, "-i", "-c", "printf 'PATH=%s\\n' \"$PATH\""], env: env, directory: home)
        let output = pty.read(until: "\n", timeout: 20)
        XCTAssertTrue(output.contains("PATH="), output)
        XCTAssertNotEqual(output.components(separatedBy: "PATH=").last?.trimmingCharacters(in: .whitespacesAndNewlines), "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
