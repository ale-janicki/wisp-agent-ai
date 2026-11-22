import Darwin
import XCTest
@testable import WispCore

final class RuntimeSyncTests: XCTestCase {
    private var dir: URL!
    private let quick = SyncWatchdog(idle: 0.6, quiet: 0.2, sample: 0.1)
    private let realLock = "error: Timeout (120s) when waiting for lock on `/x/cache` at `/x/cache/.lock`, is another uv process running? You can set `UV_LOCK_TIMEOUT` to increase the timeout."

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeUV(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("uv")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }

    private var counter: URL { dir.appendingPathComponent("count") }

    private func calls() -> Int {
        ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func run(_ uv: URL, watch: [URL] = [], steps: StepBox = StepBox()) -> String? {
        RuntimeSync.run(
            executable: uv, arguments: [], environment: [:], watch: watch, watchdog: quick, onStep: { steps.add($0) })
    }

    final class StepBox: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ step: String) { lock.withLock { all.append(step) } }
        var steps: [String] { lock.withLock { all } }
    }

    func testASilentUvIsKilledRetriedOnceAndFailsWithASentence() throws {
        let uv = try fakeUV("echo x >> '\(counter.path)'\nsleep 30")
        let failure = try XCTUnwrap(run(uv))
        XCTAssertTrue(failure.hasPrefix(RuntimeSync.idleFailure))
        XCTAssertEqual(calls(), 2)
        let gone = (0..<40).contains { _ in
            if shell("pgrep -f '[s]leep 30' | wc -l").trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return true }
            Thread.sleep(forTimeInterval: 0.05)
            return false
        }
        XCTAssertTrue(gone)
    }

    func testAUvThatKeepsPrintingIsNeverCutOffEvenPastTheIdleLimit() throws {
        let uv = try fakeUV("echo x >> '\(counter.path)'\nfor i in 1 2 3 4 5 6 7 8; do echo \"Downloading pkg$i (1MiB)\" >&2; sleep 0.2; done")
        let steps = StepBox()
        XCTAssertNil(run(uv, steps: steps))
        XCTAssertEqual(calls(), 1)
        XCTAssertEqual(steps.steps.first, "baixando pkg1")
        XCTAssertEqual(steps.steps.last, "baixando pkg8")
    }

    func testASilentUvThatKeepsGrowingTheCacheIsNotCutOff() throws {
        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let uv = try fakeUV("echo x >> '\(counter.path)'\nfor i in 1 2 3 4 5 6 7 8 9 10; do echo $i >> '\(cache.path)'/blob$i; sleep 0.2; done")
        XCTAssertNil(run(uv, watch: [cache]))
        XCTAssertEqual(calls(), 1)
    }

    func testASilentSdistBuildThatOnlyWritesToTheRuntimeTmpIsNotCutOff() throws {
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let uv = try fakeUV("echo x >> '\(counter.path)'\nfor i in 1 2 3 4 5 6 7 8 9 10; do echo $i >> \"$TMPDIR/build$i\"; sleep 0.2; done")
        let failure = RuntimeSync.run(
            executable: uv, arguments: [], environment: ["TMPDIR": tmp.path],
            watch: RuntimeSync.watchedFolders(dir, venv: dir.appendingPathComponent("venv", isDirectory: true)),
            watchdog: quick)
        XCTAssertNil(failure)
        XCTAssertEqual(calls(), 1)
    }

    func testUvBuildsInTheRuntimeTmp() {
        let layout = RuntimeLayout(bundle: URL(fileURLWithPath: "/A.app"), home: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(RuntimeBootstrap.uvEnvironment(layout)["TMPDIR"], layout.root.appendingPathComponent("tmp").path)
        XCTAssertTrue(RuntimeSync.watchedFolders(layout.root, venv: layout.venv).contains(layout.root.appendingPathComponent("tmp", isDirectory: true)))
    }

    func testAFailureNamesTheLastStepReached() throws {
        let uv = try fakeUV("echo 'Downloading cpython-3.13.1-macos-aarch64-none (20MiB)' >&2\nsleep 30")
        let failure = try XCTUnwrap(run(uv))
        XCTAssertTrue(failure.hasSuffix("Último passo: baixando o Python."), failure)
    }

    func testARealLockWaitRetriesAndTheSecondTryCanWin() throws {
        let uv = try fakeUV("""
        echo x >> '\(counter.path)'
        if [ "$(wc -l < '\(counter.path)' | tr -d ' ')" = 1 ]; then echo '\(realLock)' >&2; exit 2; fi
        exit 0
        """)
        XCTAssertNil(run(uv))
        XCTAssertEqual(calls(), 2)
    }

    func testALockThatNeverFreesFailsClearly() throws {
        let uv = try fakeUV("echo x >> '\(counter.path)'\necho '\(realLock)' >&2\nexit 2")
        XCTAssertEqual(run(uv), RuntimeSync.lockFailure)
        XCTAssertEqual(calls(), 2)
    }

    func testTheThreeRealLockMessagesAreRecognised() {
        XCTAssertTrue(RuntimeSync.isLockWait("error: Could not acquire lock"))
        XCTAssertTrue(RuntimeSync.isLockWait(realLock))
        XCTAssertTrue(RuntimeSync.isLockWait("is another uv process running?"))
    }

    func testALockfileErrorIsNotALockWaitAndShowsTheRealText() throws {
        let text = "error: Unable to read the lockfile `uv.lock`: stale lockfile, run `uv lock`"
        XCTAssertFalse(RuntimeSync.isLockWait(text))
        let uv = try fakeUV("echo x >> '\(counter.path)'\necho '\(text)' >&2\nexit 2")
        XCTAssertEqual(run(uv), text)
        XCTAssertEqual(calls(), 1)
    }

    func testAnOrdinaryFailureIsNotRetried() throws {
        let uv = try fakeUV("echo x >> '\(counter.path)'\necho 'error: no solution' >&2\nexit 1")
        XCTAssertEqual(run(uv), "error: no solution")
        XCTAssertEqual(calls(), 1)
    }

    func testLockFilesAreLeftInPlaceOnRetry() throws {
        let lock = dir.appendingPathComponent("cache/.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        let uv = try fakeUV("echo '\(realLock)' >&2\nexit 2")
        _ = run(uv, watch: [lock.deletingLastPathComponent()])
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testStepsAreReadFromUvLines() {
        XCTAssertEqual(RuntimeSync.step(from: "Downloading cpython-3.13.1-macos (20MiB)"), "baixando o Python")
        XCTAssertEqual(RuntimeSync.step(from: "Downloading mcp (150KiB)"), "baixando mcp")
        XCTAssertEqual(RuntimeSync.step(from: "Built wisp==0.3.0"), "construindo wisp")
        XCTAssertEqual(RuntimeSync.step(from: "Installed 12 packages in 20ms"), "instalando os pacotes")
        XCTAssertEqual(RuntimeSync.step(from: "Installed mcp==1.0 in 2ms"), "instalando mcp")
        XCTAssertEqual(RuntimeSync.step(from: "Built 3 packages"), "construindo os pacotes")
        XCTAssertEqual(RuntimeSync.step(from: "Downloading"), "baixando os pacotes")
        XCTAssertEqual(RuntimeSync.step(from: "Resolved 40 packages in 1s"), "resolvendo as dependências")
        XCTAssertNil(RuntimeSync.step(from: "warning: something"))
    }

    func testFailuresAreClassifiedEvenWithLastStepSuffix() {
        let suffix = " Último passo: baixando mcp."
        XCTAssertEqual(RuntimeSync.classify(RuntimeSync.lockFailure + suffix), .lock)
        XCTAssertEqual(RuntimeSync.classify(RuntimeSync.idleFailure + suffix), .stalled)
        XCTAssertEqual(RuntimeSync.classify(RuntimeSync.idleFailure), .stalled)
        XCTAssertEqual(RuntimeSync.classify("error sending request for url"), .offline)
        XCTAssertEqual(RuntimeSync.classify("boom"), .other)
    }

    func testUvGetsALockTimeout() {
        let layout = RuntimeLayout(bundle: URL(fileURLWithPath: "/A.app"), home: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(RuntimeBootstrap.uvEnvironment(layout)["UV_LOCK_TIMEOUT"], "120")
    }

    private func shell(_ command: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
