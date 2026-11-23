import XCTest
@testable import WispCore

final class SoulTests: XCTestCase {
    private func decode(_ json: String) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
    }

    private let base = #""persona":{"name":"Wisp","language":"pt-BR"},"agent":{"cwd":"~"}"#

    func testMissingSoulBlockGivesDefaults() throws {
        let profile = try decode("{\(base)}")
        XCTAssertEqual(profile.soul, Soul())
        XCTAssertNil(profile.soul.source)
        XCTAssertEqual(profile.soul.tone, .direto)
        XCTAssertFalse(profile.soul.emojis)
        XCTAssertEqual(profile.soul.extra, "")
    }

    func testFullSoulBlockDecodes() throws {
        let profile = try decode(#"{\#(base),"soul":{"source":"both","tone":"formal","emojis":true,"extra":"cite a fonte"}}"#)
        XCTAssertEqual(profile.soul, Soul(source: .both, tone: .formal, emojis: true, extra: "cite a fonte"))
    }

    func testBadFieldsFallBackOneByOne() throws {
        let profile = try decode(#"{\#(base),"soul":{"source":"nope","tone":3,"emojis":"yes","extra":"ok"}}"#)
        XCTAssertEqual(profile.soul, Soul(source: nil, tone: .direto, emojis: false, extra: "ok"))
    }

    func testMalformedSoulBlockNeverFailsTheProfile() throws {
        let profile = try decode(#"{\#(base),"soul":"garbage"}"#)
        XCTAssertEqual(profile.soul, Soul())
        XCTAssertEqual(profile.persona.name, "Wisp")
    }

    func testRendererArgumentsAndDecode() {
        XCTAssertEqual(SoulRenderer.arguments(engine: "codex"), ["soul", "render", "--engine", "codex", "--json"])
        XCTAssertEqual(SoulRenderer.decode(Data(#"{"source":"both","text":"oi"}"#.utf8)), "oi")
        XCTAssertEqual(SoulRenderer.decode(Data(#"{"source":"assistant","text":""}"#.utf8)), "")
        XCTAssertNil(SoulRenderer.decode(Data("not json".utf8)))
    }

    func testAppendingSeparatesWithABlankLineAndSkipsAnEmptySoul() {
        XCTAssertEqual(SoulRenderer.appending("alma", to: "regras"), "regras\n\nalma")
        XCTAssertEqual(SoulRenderer.appending("", to: "regras"), "regras")
    }

    func testStampChangesWhenAFileChangesAndWhenItAppears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-soul-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agente.md")
        let missing = SoulRenderer.stamp(of: [file])
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let first = SoulRenderer.stamp(of: [file])
        XCTAssertNotEqual(missing, first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: file.path)
        XCTAssertNotEqual(first, SoulRenderer.stamp(of: [file]))
    }

    func testTextIsCachedUntilTheWatchedFilesChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-soul-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("count")
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho x >> '\(counter.path)'\nprintf '{\"source\":\"wisp\",\"text\":\"alma\"}'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let watched = dir.appendingPathComponent("profile.json")
        try "{}".write(to: watched, atomically: true, encoding: .utf8)
        let cache = SoulRenderer.Cache()
        func lines() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }

        XCTAssertEqual(SoulRenderer.text(wisp: script, environment: [:], engine: "claude", watching: [watched], cache: cache), "alma")
        XCTAssertEqual(SoulRenderer.text(wisp: script, environment: [:], engine: "claude", watching: [watched], cache: cache), "alma")
        XCTAssertEqual(lines(), 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: watched.path)
        _ = SoulRenderer.text(wisp: script, environment: [:], engine: "claude", watching: [watched], cache: cache)
        XCTAssertEqual(lines(), 2)
        _ = SoulRenderer.text(wisp: script, environment: [:], engine: "codex", watching: [watched], cache: cache)
        XCTAssertEqual(lines(), 3)
    }

    func testAFailingCommandGivesNoSoulAndIsNotCached() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/wisp")
        XCTAssertEqual(SoulRenderer.text(wisp: missing, environment: [:], engine: "claude", watching: [], cache: SoulRenderer.Cache()), "")
    }

    private func fakeWisp(in dir: URL, body: String) throws -> (script: URL, count: URL) {
        let counter = dir.appendingPathComponent("count")
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho x >> '\(counter.path)'\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, counter)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-soul-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheDefaultTimeoutIsFiveSecondsAndFailuresAreRemembered60() {
        XCTAssertEqual(SoulRenderer.timeout, 5)
        XCTAssertEqual(SoulRenderer.failureTTL, 60)
    }

    func testAHangingCommandTimesOutAndTheFailureIsCachedForAMinute() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (script, counter) = try fakeWisp(in: dir, body: "sleep 30")
        let cache = SoulRenderer.Cache()
        let start = Date()
        func ask(at now: Date) -> String {
            SoulRenderer.text(wisp: script, environment: [:], engine: "claude", watching: [], timeout: 0.3, now: now, cache: cache)
        }
        func runs() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }

        XCTAssertEqual(ask(at: start), "")
        XCTAssertEqual(runs(), 1)
        XCTAssertEqual(ask(at: start.addingTimeInterval(30)), "")
        XCTAssertEqual(runs(), 1, "inside the minute the broken command is not run again")
        XCTAssertEqual(ask(at: start.addingTimeInterval(61)), "")
        XCTAssertEqual(runs(), 2, "after the minute it is tried again")
    }

    func testAChangedFileRetriesAFailureAtOnce() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (script, counter) = try fakeWisp(in: dir, body: "exit 3")
        let watched = dir.appendingPathComponent("profile.json")
        try "{}".write(to: watched, atomically: true, encoding: .utf8)
        let cache = SoulRenderer.Cache()
        func ask() -> String {
            SoulRenderer.text(wisp: script, environment: [:], engine: "claude", watching: [watched], cache: cache)
        }
        func runs() -> Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }
        _ = ask()
        _ = ask()
        XCTAssertEqual(runs(), 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: watched.path)
        _ = ask()
        XCTAssertEqual(runs(), 2)
    }

    func testTheStateIsPartOfTheStamp() {
        XCTAssertNotEqual(SoulRenderer.stamp(of: [], state: "own"), SoulRenderer.stamp(of: [], state: "managed"))
    }

    func testManagedElsewhereSeesASymlinkedClaudeFolder() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(SoulRenderer.managedElsewhere(home: home))
        let target = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: target)
        XCTAssertTrue(SoulRenderer.managedElsewhere(home: home))
    }
}
