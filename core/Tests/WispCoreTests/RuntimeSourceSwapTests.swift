import XCTest
@testable import WispCore

final class RuntimeSourceSwapTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        chmodTree(root, 0o700)
        try? fm.removeItem(at: root)
    }

    private func chmodTree(_ url: URL, _ mode: Int) {
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in walker { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: item.path) }
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func bundledSource() throws -> URL {
        let bundled = root.appendingPathComponent("bundled/src", isDirectory: true)
        try write("[project]", bundled.appendingPathComponent("pyproject.toml"))
        try write("lock", bundled.appendingPathComponent("uv.lock"))
        return bundled
    }

    private func names() throws -> [String] { try fm.contentsOfDirectory(atPath: root.appendingPathComponent("runtime").path).sorted() }

    func testSwapFromNoPreviousSource() throws {
        let destination = root.appendingPathComponent("runtime/src", isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RuntimeSourceSwap.install(bundled: bundledSource(), destination: destination)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("pyproject.toml").path))
        XCTAssertEqual(try names(), ["src"])
    }

    func testSwapReplacesOldSourceAndRemovesIt() throws {
        let destination = root.appendingPathComponent("runtime/src", isDirectory: true)
        try write("old", destination.appendingPathComponent("stale.txt"))
        try RuntimeSourceSwap.install(bundled: bundledSource(), destination: destination)
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("uv.lock").path))
        XCTAssertEqual(try names(), ["src"])
    }

    func testUndeletableOldSourceDoesNotFailTheSwap() throws {
        let destination = root.appendingPathComponent("runtime/src", isDirectory: true)
        let cache = destination.appendingPathComponent("cli/src/wisp/__pycache__", isDirectory: true)
        try write("pyc", cache.appendingPathComponent("cli.pyc"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        var logged: [String] = []
        try RuntimeSourceSwap.install(bundled: bundledSource(), destination: destination, log: { logged.append($0) })
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("pyproject.toml").path))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("uv.lock").path))
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("cli").path))
        XCTAssertEqual(try names().filter { $0.hasPrefix("src.old-") }.count, 1)
        XCTAssertEqual(logged.count, 1)
    }

    func testSweepRemovesOnlyLeftovers() throws {
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try write("a", runtime.appendingPathComponent("src.old-1/a"))
        try write("b", runtime.appendingPathComponent("src.new-2/b"))
        try write("keep", runtime.appendingPathComponent("src/keep"))
        try write("keep", runtime.appendingPathComponent("venv/keep"))
        RuntimeSourceSwap.sweepLeftovers(of: runtime.appendingPathComponent("src", isDirectory: true))
        XCTAssertEqual(try names(), ["src", "venv"])
    }

    func testFailedCopyLeavesCurrentSourceUntouched() throws {
        let destination = root.appendingPathComponent("runtime/src", isDirectory: true)
        try write("old", destination.appendingPathComponent("keep.txt"))
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try RuntimeSourceSwap.install(bundled: missing, destination: destination))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("keep.txt").path))
        XCTAssertEqual(try names(), ["src"])
    }
}
