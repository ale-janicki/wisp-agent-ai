import XCTest
@testable import WispCore

final class LoginPATHCacheTests: XCTestCase {
    func testFoundPathIsCachedAndNotFetchedAgain() {
        let cache = LoginPATHCache()
        var calls = 0
        XCTAssertEqual(cache.value(fetch: { calls += 1; return "/a:/b" }), "/a:/b")
        XCTAssertEqual(cache.value(fetch: { calls += 1; return "/c" }), "/a:/b")
        XCTAssertEqual(calls, 1)
    }

    func testFailedFetchUsesFallbackAndRetriesLater() {
        let cache = LoginPATHCache()
        let start = Date(timeIntervalSince1970: 1_000)
        var calls = 0
        let first = cache.value(now: start, base: "/usr/bin:/bin", home: "/h", fetch: { calls += 1; return nil })
        XCTAssertTrue(first.hasPrefix("/usr/bin:/bin:/h/.local/bin"))
        XCTAssertTrue(first.contains("/opt/homebrew/bin"))
        _ = cache.value(now: start.addingTimeInterval(5), base: nil, home: "/h", fetch: { calls += 1; return "/x" })
        XCTAssertEqual(calls, 1, "no retry inside the interval")
        let later = cache.value(now: start.addingTimeInterval(31), base: nil, home: "/h", fetch: { calls += 1; return "/x" })
        XCTAssertEqual(later, "/x")
        XCTAssertEqual(calls, 2)
    }

    func testFallbackHasNoDuplicates() {
        let path = LoginPATHCache.fallback(base: "/usr/local/bin:/usr/bin", home: "/h")
        let parts = path.split(separator: ":")
        XCTAssertEqual(parts.count, Set(parts).count)
        XCTAssertEqual(parts.first, "/usr/local/bin")
    }

    func testStopsRetryingAfterMaxAttempts() {
        let cache = LoginPATHCache()
        var calls = 0
        for step in 0..<6 {
            _ = cache.value(now: Date(timeIntervalSince1970: Double(step) * 40), base: nil, home: "/h", fetch: { calls += 1; return nil })
        }
        XCTAssertEqual(calls, LoginPATHCache.maxAttempts)
    }
}
