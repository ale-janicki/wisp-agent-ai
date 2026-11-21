import XCTest
@testable import WispCore

private actor Ticks {
    private(set) var sleeps: [TimeInterval] = []
    private(set) var count = 0
    func slept(_ seconds: TimeInterval) { sleeps.append(seconds) }
    func ticked() { count += 1 }
}

final class BrainColherTests: XCTestCase {
    func testCountsReadOnlyTheListLengths() {
        let json = Data(#"{"colhidas":["a"],"puladas":[{"sid":"x","motivo":"m"},{"sid":"-","motivo":"n"}]}"#.utf8)
        XCTAssertEqual(BrainColher.counts(from: json), BrainColher.Counts(harvested: 1, skipped: 2))
        XCTAssertNil(BrainColher.counts(from: Data("nope".utf8)))
        XCTAssertNil(BrainColher.counts(from: Data("{}".utf8)))
    }

    func testEnvironmentDropsUVAndNamesRuntimeSources() {
        let wisp = URL(fileURLWithPath: "/h/.local/share/wisp/runtime/venv/bin/wisp")
        let env = BrainColher.environment(
            wisp: wisp, base: ["UV_X": "1", "PYTHONPATH": "p", "HOME": "/h", "PATH": "/usr/bin"], loginPATH: "/opt/bin")
        XCTAssertNil(env["UV_X"])
        XCTAssertNil(env["PYTHONPATH"])
        XCTAssertEqual(env["WISP_RESOURCES"], "/h/.local/share/wisp/runtime/src")
        XCTAssertEqual(env["PATH"], "/opt/bin")
        XCTAssertEqual(env["HOME"], "/h")
    }

    func testRunParsesTheCLIReport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho '{\"colhidas\":[],\"puladas\":[{}]}'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let counts = await BrainColher.run(wisp: script, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(counts, BrainColher.Counts(harvested: 0, skipped: 1))
    }

    func testCancellingTheTaskKillsTheHarvestGroup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let task = Task { await BrainColher.run(wisp: script, environment: ["PATH": "/usr/bin:/bin"]) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let started = Date()
        task.cancel()
        let counts = await task.value
        XCTAssertNil(counts)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testSchedulerWaitsFirstThenIntervalAndStops() async throws {
        let ticks = Ticks()
        let scheduler = BrainColherScheduler(
            first: 120, interval: 600,
            sleep: { await ticks.slept($0); await Task.yield() },
            tick: { await ticks.ticked() })
        scheduler.start()
        scheduler.start()
        for _ in 0..<200 where await ticks.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        scheduler.stop()
        let sleeps = await ticks.sleeps
        XCTAssertEqual(Array(sleeps.prefix(3)), [120, 600, 600])
        let after = await ticks.count
        try await Task.sleep(for: .milliseconds(50))
        let final = await ticks.count
        XCTAssertLessThanOrEqual(final - after, 1)
    }
}

final class WispConfigFileTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSetKeepsUnknownKeysAndMode() throws {
        let url = try temp().appendingPathComponent("wisp.json")
        try #"{"brain":"~/old","telegram":{"chat_id":1},"future":[1,2]}"#.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = WispConfigFile(url: url)
        try file.setString("brain", to: "/new/brain")
        try file.setBool("brain_learn", to: false)
        XCTAssertEqual(file.string("brain"), "/new/brain")
        XCTAssertFalse(file.bool("brain_learn", default: true))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual((raw?["telegram"] as? [String: Any])?["chat_id"] as? Int, 1)
        XCTAssertEqual(raw?["future"] as? [Int], [1, 2])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testMissingFileIsCreatedPrivateAndDefaultsApply() throws {
        let url = try temp().appendingPathComponent("sub/wisp.json")
        let file = WispConfigFile(url: url)
        XCTAssertTrue(file.bool("brain_learn", default: true))
        try file.setBool("brain_learn", to: false)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testRefusesSymlinkAndGarbage() throws {
        let dir = try temp()
        let real = dir.appendingPathComponent("real.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("wisp.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try WispConfigFile(url: link).setBool("brain_learn", to: true)) {
            XCTAssertEqual($0 as? WispConfigFile.Failure, .isSymlink)
        }
        let bad = dir.appendingPathComponent("bad.json")
        try "[1]".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WispConfigFile(url: bad).setString("brain", to: "x"))
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "[1]")
    }
}

final class ProfileMemoryFileTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSetsRootKeepingSearchUnknownKeysAndMode() throws {
        let url = try temp().appendingPathComponent("profile.json")
        try #"{"name":"Wisp","blocks":{"tasks":{"file":"/a/pendencias.md"},"memory":{"search":"grep {query} {root}","root":"/old"}},"future":[1]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(try ProfileMemoryFile(url: url).setRoot("/new/brain"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let blocks = raw?["blocks"] as? [String: Any]
        let memory = blocks?["memory"] as? [String: Any]
        XCTAssertEqual(memory?["root"] as? String, "/new/brain")
        XCTAssertEqual(memory?["search"] as? String, "grep {query} {root}")
        XCTAssertEqual((blocks?["tasks"] as? [String: Any])?["file"] as? String, "/a/pendencias.md")
        XCTAssertEqual(raw?["name"] as? String, "Wisp")
        XCTAssertEqual(raw?["future"] as? [Int], [1])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testMovesTasksFileOnlyWhenItFollowedTheOldRoot() throws {
        let dir = try temp()
        let following = dir.appendingPathComponent("a.json")
        try #"{"blocks":{"tasks":{"file":"/old/./brain/pendencias.md"},"memory":{"root":"/old/brain/"}}}"#
            .write(to: following, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ProfileMemoryFile(url: following).setRoot("/new/brain"))
        let moved = try JSONSerialization.jsonObject(with: Data(contentsOf: following)) as? [String: Any]
        let movedTasks = (moved?["blocks"] as? [String: Any])?["tasks"] as? [String: Any]
        XCTAssertEqual(movedTasks?["file"] as? String, "/new/brain/pendencias.md")

        let custom = dir.appendingPathComponent("b.json")
        try #"{"blocks":{"tasks":{"file":"/elsewhere/todo.md"},"memory":{"root":"/old/brain"}}}"#
            .write(to: custom, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ProfileMemoryFile(url: custom).setRoot("/new/brain"))
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: custom)) as? [String: Any]
        let keptTasks = (kept?["blocks"] as? [String: Any])?["tasks"] as? [String: Any]
        XCTAssertEqual(keptTasks?["file"] as? String, "/elsewhere/todo.md")
    }

    func testCreatesMemoryBlockWhenAbsent() throws {
        let url = try temp().appendingPathComponent("profile.json")
        try #"{"name":"Wisp"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(try ProfileMemoryFile(url: url).setRoot("/b"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(((raw?["blocks"] as? [String: Any])?["memory"] as? [String: Any])?["root"] as? String, "/b")
    }

    func testSkipsMissingFileAndNeverWritesThroughSymlink() throws {
        let dir = try temp()
        XCTAssertFalse(try ProfileMemoryFile(url: dir.appendingPathComponent("none.json")).setRoot("/b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("none.json").path))
        let real = dir.appendingPathComponent("real.json")
        try #"{"blocks":{}}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("profile.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertFalse(try ProfileMemoryFile(url: link).setRoot("/b"))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), #"{"blocks":{}}"#)
    }

    func testGarbageProfileThrowsAndIsUntouched() throws {
        let url = try temp().appendingPathComponent("profile.json")
        try "[1]".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ProfileMemoryFile(url: url).setRoot("/b"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1]")
    }
}
