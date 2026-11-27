import XCTest
@testable import WispCore

final class AlertListTests: XCTestCase {
    func testParsesOffsetsAndFractionalSeconds() {
        let expected = Date(timeIntervalSince1970: 1_794_427_112)
        for stamp in [
            "2026-11-11T16:58:32-03:00", "2026-11-11T19:58:32Z", "2026-11-11T19:58:32.000Z",
            "2026-11-11T16:58:32.000-03:00", "2026-11-11T16:58:32-0300", "2026-11-11T22:28:32+0230",
        ] {
            XCTAssertEqual(AlertList.date(stamp), expected, stamp)
        }
        XCTAssertEqual(AlertList.date("2026-11-11T19:58:32.500Z")?.timeIntervalSince1970 ?? 0, 1_794_427_112.5, accuracy: 0.001)
        XCTAssertNil(AlertList.date("ontem"))
    }

    func testAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AlertList.age(of: now.addingTimeInterval(-30), now: now), "agora")
        XCTAssertEqual(AlertList.age(of: now.addingTimeInterval(-12 * 60), now: now), "12 min")
        XCTAssertEqual(AlertList.age(of: now.addingTimeInterval(-3 * 3_600 - 5), now: now), "3 h")
        XCTAssertEqual(AlertList.age(of: now.addingTimeInterval(-2 * 86_400 - 5), now: now), "2 d")
        XCTAssertEqual(AlertList.age(of: now.addingTimeInterval(60), now: now), "agora")
    }
}

final class BlockCommandTests: XCTestCase {
    func testReturnsStdout() throws {
        let data = try BlockCommand.run(#"printf '[{"chave":"x"}]'"#).get()
        XCTAssertEqual(String(data: data, encoding: .utf8), #"[{"chave":"x"}]"#)
    }

    func testUsesGivenPATH() throws {
        let data = try BlockCommand.run(#"printf %s "$PATH""#, path: "/usr/bin:/bin:/custom").get()
        XCTAssertEqual(String(data: data, encoding: .utf8), "/usr/bin:/bin:/custom")
    }

    func testFailureCarriesFirstStderrLine() {
        let result = BlockCommand.run("echo 'sem permissão' >&2; echo segunda >&2; exit 3")
        XCTAssertEqual(result.failure, .failed(status: 3, message: "sem permissão"))
    }

    func testTimesOut() {
        let started = Date()
        let result = BlockCommand.run("sleep 5", timeout: 0.3)
        XCTAssertEqual(result.failure, .timedOut(seconds: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTimeoutKillsGrandchildProcessGroup() throws {
        let marker = "wisp-pg-\(UUID().uuidString)"
        _ = BlockCommand.run("sleep 30 && echo \(marker) & sleep 30", timeout: 0.3)
        Thread.sleep(forTimeInterval: 0.3)
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        pgrep.standardOutput = FileHandle.nullDevice
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertEqual(pgrep.terminationStatus, 1, "a grandchild survived the timeout")
    }

    func testLargeOutputDoesNotStall() throws {
        let data = try BlockCommand.run("head -c 300000 /dev/zero | tr '\\\\0' a").get()
        XCTAssertEqual(data.count, 300_000)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
