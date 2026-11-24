import XCTest
@testable import WispCore

final class TerminalShellTests: XCTestCase {
    func testShellVariableWinsWhenUsable() {
        let shell = TerminalShell.resolve(shellVariable: "/bin/bash")
        XCTAssertEqual(shell.path, "/bin/bash")
        XCTAssertEqual(shell.name, "bash")
    }

    func testMissingVariableFallsBackToZsh() {
        XCTAssertEqual(TerminalShell.resolve(shellVariable: nil).path, "/bin/zsh")
        XCTAssertEqual(TerminalShell.resolve(shellVariable: "").path, "/bin/zsh")
        XCTAssertEqual(TerminalShell.resolve(shellVariable: "   ").path, "/bin/zsh")
    }

    func testInvalidVariableFallsBackToZsh() {
        for bad in ["zsh", "/nonexistent/shell", "/tmp", "/usr/bin/false", "/usr/bin/nologin", "../bin/zsh"] {
            XCTAssertEqual(TerminalShell.resolve(shellVariable: bad).path, "/bin/zsh", bad)
        }
    }

    func testUsabilityCanBeInjected() {
        let shell = TerminalShell.resolve(shellVariable: "/opt/x/fish") { $0 == "/opt/x/fish" }
        XCTAssertEqual(shell.path, "/opt/x/fish")
        XCTAssertEqual(TerminalShell.resolve(shellVariable: "/opt/x/fish") { _ in false }.path, "/bin/zsh")
    }

    func testLoginArgvHasTheLeadingDash() {
        XCTAssertEqual(TerminalShell(path: "/bin/zsh").loginName, "-zsh")
        XCTAssertEqual(TerminalShell(path: "/opt/homebrew/bin/fish").loginName, "-fish")
        XCTAssertEqual(TerminalShell(path: "/bin/zsh").arguments, [])
    }
}
