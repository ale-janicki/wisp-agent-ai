import XCTest
@testable import WispCore

final class CommandRunnerTests: XCTestCase {
    func testNonZeroExitKeepsStdout() throws {
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo {}; exit 1"], timeout: 5)
        let output = try result.get()
        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "{}\n")
        XCTAssertFalse(output.timedOut)
    }

    func testStdinIsDelivered() throws {
        let output = try CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: Data("token".utf8), timeout: 5).get()
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "token")
    }

    func testStderrIsCaptured() throws {
        let output = try CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo oops >&2"], timeout: 5).get()
        XCTAssertEqual(String(data: output.stderr, encoding: .utf8), "oops\n")
    }

    func testEnvironmentReplacesTheParents() throws {
        let output = try CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo $WISP_T"],
            environment: ["WISP_T": "x"], timeout: 5).get()
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "x\n")
    }

    func testTimeoutKillsGroup() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-runner-\(UUID().uuidString)")
        let started = Date()
        let output = try CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 1; touch \(marker.path)) & sleep 30"], timeout: 0.3).get()
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the child of the group survived")
    }

    func testMissingExecutableIsLaunchFailed() {
        let result = CommandRunner.run(executable: URL(fileURLWithPath: "/nonexistent/x"), arguments: [], timeout: 1)
        guard case .failure(.launchFailed) = result else { return XCTFail("\(result)") }
    }
}
