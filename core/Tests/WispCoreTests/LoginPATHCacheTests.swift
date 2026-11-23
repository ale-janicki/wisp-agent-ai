import XCTest
@testable import WispCore

final class LoginPATHCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func inline(_ work: @escaping @Sendable () -> Void) { work() }

    func testFirstLookupRunsInlineAndIsCached() {
        let cache = LoginPATHCache()
        let calls = Counter()
        XCTAssertEqual(cache.found(now: now, fetch: { calls.bump(); return "/a:/b" }, retry: inline), "/a:/b")
        XCTAssertEqual(cache.found(now: now, fetch: { calls.bump(); return "/c" }, retry: inline), "/a:/b")
        XCTAssertEqual(calls.value, 1)
    }

    func testFailureReturnsNilAndRetriesOffTheCallerAfterTheInterval() {
        let cache = LoginPATHCache()
        var scheduled: [@Sendable () -> Void] = []
        let calls = Counter()
        XCTAssertNil(cache.found(now: now, fetch: { calls.bump(); return nil }, retry: { scheduled.append($0) }))
        XCTAssertNil(cache.found(now: now.addingTimeInterval(5), fetch: { calls.bump(); return "/x" }, retry: { scheduled.append($0) }))
        XCTAssertEqual(calls.value, 1, "no retry inside the interval")
        XCTAssertNil(cache.found(now: now.addingTimeInterval(31), fetch: { calls.bump(); return "/x" }, retry: { scheduled.append($0) }),
                     "a retry never runs on the calling thread")
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(scheduled.count, 1)
        scheduled[0]()
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(cache.found(now: now.addingTimeInterval(32), fetch: { calls.bump(); return "/y" }, retry: inline), "/x")
    }

    func testStopsRetryingAfterMaxAttempts() {
        let cache = LoginPATHCache()
        let calls = Counter()
        for step in 0..<8 {
            _ = cache.found(now: now.addingTimeInterval(Double(step) * 40), fetch: { calls.bump(); return nil }, retry: inline)
        }
        XCTAssertEqual(calls.value, LoginPATHCache.maxAttempts)
    }

    func testFallbackKeepsBaseFirstAndHasNoDuplicates() {
        let path = LoginPATHCache.fallback(base: "/usr/local/bin:/usr/bin", home: "/h")
        let parts = path.split(separator: ":")
        XCTAssertEqual(parts.count, Set(parts).count)
        XCTAssertEqual(parts.first, "/usr/local/bin")
        XCTAssertTrue(parts.contains("/h/.local/bin"))
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
