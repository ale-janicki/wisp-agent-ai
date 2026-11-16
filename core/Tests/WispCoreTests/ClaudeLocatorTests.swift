import XCTest
@testable import WispCore

final class ClaudeLocatorTests: XCTestCase {
    func testResolvesViaLoginShell() throws {
        let original = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin", 1)
        defer { if let original { setenv("PATH", original, 1) } }
        let url = try ClaudeLocator.resolve(configured: nil)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testConfiguredPathWins() throws {
        let url = try ClaudeLocator.resolve(configured: "/bin/echo")
        XCTAssertEqual(url.path, "/bin/echo")
    }

    func testMissingEverywhereThrows() {
        let home = NSTemporaryDirectory() + "wisp-empty-home-\(UUID().uuidString)"
        XCTAssertThrowsError(
            try ClaudeLocator.resolve(configured: nil, shell: "/usr/bin/false", home: home)
        ) { error in
            XCTAssertEqual(error as? AgentError, .claudeNotFound)
        }
    }

    func testConfiguredBadPathThrows() {
        XCTAssertThrowsError(try ClaudeLocator.resolve(configured: "/nonexistent/claude")) { error in
            XCTAssertEqual(error as? AgentError, .configuredClaudeNotExecutable(path: "/nonexistent/claude"))
            XCTAssertTrue(error.localizedDescription.contains("perfil"))
        }
    }

    func testLoginShellPATHContainsLocalBin() throws {
        let path = try XCTUnwrap(ClaudeLocator.loginShellPATH())
        XCTAssertTrue(path.contains("/.local/bin"), path)
    }
}
