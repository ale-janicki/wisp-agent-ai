import XCTest
@testable import WispCore

final class SessionLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-locks-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCreatesThePrivateDirectoryAndOneFilePerSession() throws {
        let lock = SessionLock(directory: directory)
        let lease = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        defer { lease.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("s-1.lock").path))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testSecondHolderOfTheSameSessionIsRefusedUntilRelease() throws {
        let lock = SessionLock(directory: directory)
        let first = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        XCTAssertNil(try lock.tryAcquire(sessionId: "s-1"))
        let other = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-2"))
        other.release()
        first.release()
        let again = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        again.release()
    }

    func testDroppingTheLeaseFreesTheSession() throws {
        let lock = SessionLock(directory: directory)
        var lease: SessionLock.Lease? = try lock.tryAcquire(sessionId: "s-1")
        XCTAssertNotNil(lease)
        XCTAssertNil(try lock.tryAcquire(sessionId: "s-1"))
        lease = nil
        let again = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        again.release()
    }

    func testAcquireWaitsForTheHolderAndSaysItWasBusy() async throws {
        let lock = SessionLock(directory: directory, poll: .milliseconds(10))
        let first = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        let busy = Flag()
        let waiter = Task { try await lock.acquire(sessionId: "s-1", onBusy: { busy.set() }) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(busy.value)
        first.release()
        let second = try await waiter.value
        second.release()
    }

    func testAcquireOnAFreeSessionNeverReportsBusy() async throws {
        let lock = SessionLock(directory: directory)
        let busy = Flag()
        let lease = try await lock.acquire(sessionId: "s-1", onBusy: { busy.set() })
        lease.release()
        XCTAssertFalse(busy.value)
    }

    func testRefusesSessionIdsThatEscapeTheDirectory() {
        let lock = SessionLock(directory: directory)
        XCTAssertThrowsError(try lock.tryAcquire(sessionId: "../x"))
        XCTAssertThrowsError(try lock.tryAcquire(sessionId: ""))
    }

    func testCancellingABlockedWaitReturnsPromptlyWithoutALease() async throws {
        let lock = SessionLock(directory: directory, poll: .milliseconds(20))
        let holder = try XCTUnwrap(try lock.tryAcquire(sessionId: "s-1"))
        defer { holder.release() }
        let waiter = Task { try await lock.acquire(sessionId: "s-1") }
        try await Task.sleep(for: .milliseconds(80))
        let started = ContinuousClock.now
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled wait must not return a lease")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertNil(try lock.tryAcquire(sessionId: "s-1"), "the holder still has it")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}
