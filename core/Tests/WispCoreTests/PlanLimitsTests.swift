import XCTest
@testable import WispCore

final class PlanLimitsTests: XCTestCase {
    private let file = #"{"five_hour":{"used_percentage":34,"resets_at":1794880800},"seven_day":{"used_percentage":61.5,"resets_at":1795122000},"captured_at":1794863508}"#
    private let now = Date(timeIntervalSince1970: 1_794_863_800)

    func testParsesStatuslineFile() throws {
        let snapshot = try XCTUnwrap(PlanLimitsSnapshot(json: Data(file.utf8)))
        XCTAssertEqual(snapshot.capturedAt, Date(timeIntervalSince1970: 1_794_863_508))
        XCTAssertEqual(snapshot.limit.fiveHour?.utilization ?? 0, 0.34, accuracy: 1e-9)
        XCTAssertEqual(snapshot.limit.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_794_880_800))
        XCTAssertEqual(snapshot.limit.sevenDay?.utilization ?? 0, 0.615, accuracy: 1e-9)
    }

    func testPartialAndBrokenFiles() {
        let onlyWeek = #"{"seven_day":{"used_percentage":10,"resets_at":1795122000},"captured_at":5}"#
        let snapshot = PlanLimitsSnapshot(json: Data(onlyWeek.utf8))
        XCTAssertNil(snapshot?.limit.fiveHour)
        XCTAssertEqual(snapshot?.limit.sevenDay?.utilization ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertNil(PlanLimitsSnapshot(json: Data("not json".utf8)))
        XCTAssertNil(PlanLimitsSnapshot(json: Data(#"{"captured_at":5}"#.utf8)))
        XCTAssertNil(PlanLimitsSnapshot(json: Data(#"{"five_hour":{"used_percentage":1}}"#.utf8)))
    }

    func testReadsFromPathAndMissingFileIsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-limits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(PlanLimitsSnapshot.read(path: url.path))
        try Data(file.utf8).write(to: url)
        XCTAssertNotNil(PlanLimitsSnapshot.read(path: url.path))
    }

    func testNewestWins() {
        let older = PlanLimitsSnapshot(limit: RateLimit(fiveHour: RateLimitWindow(utilization: 0.1)), capturedAt: Date(timeIntervalSince1970: 100))
        let newer = PlanLimitsSnapshot(limit: RateLimit(fiveHour: RateLimitWindow(utilization: 0.2)), capturedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(PlanLimitsSnapshot.newest(older, newer), newer)
        XCTAssertEqual(PlanLimitsSnapshot.newest(newer, older), newer)
        XCTAssertEqual(PlanLimitsSnapshot.newest(nil, older), older)
        XCTAssertEqual(PlanLimitsSnapshot.newest(older, nil), older)
        XCTAssertNil(PlanLimitsSnapshot.newest(nil, nil))
    }

    func testRowsShowPercentAndReset() throws {
        let snapshot = try XCTUnwrap(PlanLimitsSnapshot(json: Data(file.utf8)))
        let rows = snapshot.rows(now: now)
        XCTAssertEqual(rows.map(\.kind), [.session, .week])
        XCTAssertEqual(rows[0].state, .used(percent: 34, resetsAt: Date(timeIntervalSince1970: 1_794_880_800), severity: .normal))
        XCTAssertEqual(rows[1].state, .used(percent: 62, resetsAt: Date(timeIntervalSince1970: 1_795_122_000), severity: .normal))
    }

    func testPassedResetShowsRenewedNotStalePercent() throws {
        let snapshot = try XCTUnwrap(PlanLimitsSnapshot(json: Data(file.utf8)))
        let rows = snapshot.rows(now: Date(timeIntervalSince1970: 1_794_880_800))
        XCTAssertEqual(rows[0].state, .renewed)
        XCTAssertEqual(rows[1].kind, .week)
        if case .used = rows[1].state {} else { XCTFail("week has not reset yet") }
    }

    func testSeverityThresholds() {
        XCTAssertEqual(PlanLimitSeverity(utilization: 0.749), .normal)
        XCTAssertEqual(PlanLimitSeverity(utilization: 0.75), .warning)
        XCTAssertEqual(PlanLimitSeverity(utilization: 0.899), .warning)
        XCTAssertEqual(PlanLimitSeverity(utilization: 0.90), .critical)
        XCTAssertEqual(PlanLimitSeverity(utilization: 1.2), .critical)
    }

    func testWindowWithoutResetTimeStaysUsed() {
        let snapshot = PlanLimitsSnapshot(limit: RateLimit(fiveHour: RateLimitWindow(utilization: 0.8)), capturedAt: now)
        XCTAssertEqual(snapshot.rows(now: now).map(\.state), [.used(percent: 80, resetsAt: nil, severity: .warning)])
    }

    func testAgeCaption() {
        let base = Date(timeIntervalSince1970: 10_000)
        func age(_ seconds: TimeInterval) -> String { PlanLimitsSnapshot.age(of: base, now: base.addingTimeInterval(seconds)) }
        XCTAssertEqual(age(20), "atualizado agora")
        XCTAssertEqual(age(-5), "atualizado agora")
        XCTAssertEqual(age(180), "atualizado há 3 min")
        XCTAssertEqual(age(2 * 3600 + 10), "atualizado há 2 h")
        XCTAssertEqual(age(3 * 86_400), "atualizado há 3 d")
    }

    func testProfileUsageBlock() throws {
        let json = #"{"persona":{"name":"K","language":"pt-BR"},"agent":{"cwd":"~"},"blocks":{"usage":{"limits":"~/.claude/state/rate-limits.json"}}}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.blocks?.usage?.limits, "~/.claude/state/rate-limits.json")
    }
}
