import XCTest
@testable import WispCore

final class RuntimeLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snap(_ age: TimeInterval, current: Bool = false, process: Bool = true, busy: Bool = false, unseen: Bool = false) -> RuntimeSnapshot {
        RuntimeSnapshot(id: UUID(), isCurrent: current, hasProcess: process, isBusy: busy, hasUnseenReply: unseen,
                        lastUsed: now.addingTimeInterval(-age))
    }

    func testKeepsFourMostRecentIdleProcessesAndStopsTheRest() {
        let all = (1...6).map { snap(TimeInterval($0) * 10) }
        let stop = RuntimeLifecycle.processesToStop(all, now: now)
        XCTAssertEqual(Set(stop), Set([all[4].id, all[5].id]))
    }

    func testNeverStopsBusyOrCurrent() {
        var all = (1...5).map { snap(TimeInterval($0) * 10) }
        let busy = snap(500, busy: true)
        let current = snap(400, current: true)
        all += [busy, current]
        let stop = RuntimeLifecycle.processesToStop(all, now: now)
        XCTAssertFalse(stop.contains(busy.id))
        XCTAssertFalse(stop.contains(current.id))
    }

    func testBusyRuntimesDoNotCountTowardTheCap() {
        let busy = (0..<3).map { snap(TimeInterval($0), busy: true) }
        let idle = (1...4).map { snap(TimeInterval($0) * 10) }
        XCTAssertTrue(RuntimeLifecycle.processesToStop(busy + idle, now: now).isEmpty)
    }

    func testStopsAnIdleProcessPastTheTimeout() {
        let old = snap(RuntimeLifecycle.idleTimeout + 1)
        let fresh = snap(5)
        XCTAssertEqual(RuntimeLifecycle.processesToStop([old, fresh], now: now), [old.id])
    }

    func testRuntimesWithoutProcessAreNotStopped() {
        XCTAssertTrue(RuntimeLifecycle.processesToStop([snap(99999, process: false)], now: now).isEmpty)
    }

    func testDropsOnlyWhatHasNothingLeftToKeep() {
        let drop = snap(10, process: false)
        let keep = [
            snap(10, current: true, process: false), snap(10, process: true), snap(10, process: false, busy: true),
            snap(10, process: false, unseen: true),
        ]
        XCTAssertEqual(RuntimeLifecycle.runtimesToDrop([drop] + keep), [drop.id])
    }

    func testRowActivity() {
        typealias A = RowActivity
        XCTAssertEqual(A.of(isCurrent: true, isThinking: true, hasApproval: true, hasUnseenReply: true), .none)
        XCTAssertEqual(A.of(isCurrent: false, isThinking: true, hasApproval: false, hasUnseenReply: false), .thinking)
        XCTAssertEqual(A.of(isCurrent: false, isThinking: true, hasApproval: true, hasUnseenReply: false), .attention)
        XCTAssertEqual(A.of(isCurrent: false, isThinking: false, hasApproval: false, hasUnseenReply: true), .attention)
        XCTAssertEqual(A.of(isCurrent: false, isThinking: false, hasApproval: false, hasUnseenReply: false), .none)
    }

    func testSharingShowsEvenOnTheCurrentConversation() {
        typealias A = RowActivity
        XCTAssertEqual(A.of(isCurrent: true, isThinking: false, hasApproval: false, hasUnseenReply: false, isSharing: true), .sharing)
        XCTAssertEqual(A.of(isCurrent: false, isThinking: true, hasApproval: true, hasUnseenReply: true, isSharing: true), .sharing)
    }
}
