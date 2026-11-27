import XCTest
@testable import WispCore

final class RoutineDiscoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ file: String, _ plist: [String: Any]) throws -> String {
        let url = dir.appendingPathComponent(file)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url.path
    }

    func testDiscoversOnlyPrefixedLabelsSortedWithScheduleAndLogs() throws {
        try write("b.plist", ["Label": "com.ale.beta", "StartInterval": 300, "StandardOutPath": "/tmp/b.log", "StandardErrorPath": "/tmp/b.err"])
        try write("a.plist", ["Label": "com.ale.alpha", "KeepAlive": true])
        try write("g.plist", ["Label": "com.google.keystone", "StartInterval": 60])
        try write("junk.plist", ["NoLabel": 1])
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let jobs = RoutineDiscovery.discover(agents: dir.path, prefixes: ["com.ale."])
        XCTAssertEqual(jobs.map(\.label), ["com.ale.alpha", "com.ale.beta"])
        XCTAssertEqual(jobs[0].name, "alpha")
        XCTAssertEqual(jobs[0].description, "sempre ligado")
        XCTAssertEqual(jobs[1].description, "a cada 5 min")
        XCTAssertEqual(jobs[1].logs, ["/tmp/b.log", "/tmp/b.err"])
        XCTAssertTrue(RoutineDiscovery.discover(agents: dir.path, prefixes: []).isEmpty)
    }

    func testScheduleDescriptions() {
        func text(_ plist: [String: Any]) -> String { RoutineDiscovery.schedule(fromPlist: plist) }
        XCTAssertEqual(text(["StartInterval": 30]), "a cada 30 s")
        XCTAssertEqual(text(["StartInterval": 600]), "a cada 10 min")
        XCTAssertEqual(text(["StartInterval": 7200]), "a cada 2 h")
        XCTAssertEqual(text(["StartCalendarInterval": ["Hour": 8, "Minute": 30]]), "todo dia 08:30")
        XCTAssertEqual(text(["StartCalendarInterval": ["Hour": 9, "Minute": 0, "Weekday": 1]]), "toda seg 09:00")
        XCTAssertEqual(text(["StartCalendarInterval": [["Hour": 8, "Minute": 0], ["Hour": 20, "Minute": 0]]]), "2 horários")
        XCTAssertEqual(text(["KeepAlive": ["SuccessfulExit": false], "StartInterval": 60]), "sempre ligado")
        XCTAssertEqual(text(["KeepAlive": false, "RunAtLoad": true]), "ao ligar")
        XCTAssertEqual(text([:]), "sob demanda")
    }

    func testMergeRegistryWinsAndFlagsMissingPlist() throws {
        let onDisk = try write("sync.plist", ["Label": "com.ale.sync", "StartInterval": 300, "StandardOutPath": "/tmp/s.log"])
        let discovered = RoutineDiscovery.discover(agents: dir.path, prefixes: ["com.ale."])
        let registry = [
            RoutineJob(label: "com.ale.sync", name: "Sync bonito", description: "Faz sync.", plist: onDisk, logs: ["/tmp/mine.log"]),
            RoutineJob(label: "com.ale.ghost", name: "Fantasma", plist: dir.appendingPathComponent("ghost.plist").path),
        ]
        try write("extra.plist", ["Label": "com.ale.extra", "KeepAlive": true])
        let all = RoutineDiscovery.merge(registry: registry, discovered: RoutineDiscovery.discover(agents: dir.path, prefixes: ["com.ale."]))
        XCTAssertEqual(all.map(\.label), ["com.ale.sync", "com.ale.ghost", "com.ale.extra"])
        XCTAssertEqual(all[0].name, "Sync bonito")
        XCTAssertEqual(all[0].description, "Faz sync.")
        XCTAssertEqual(all[0].logs, ["/tmp/mine.log"])
        XCTAssertTrue(all[0].installed)
        XCTAssertFalse(all[1].installed)
        XCTAssertEqual(all[2].name, "extra")
        XCTAssertEqual(all[2].description, "sempre ligado")
        XCTAssertEqual(discovered.count, 1)
    }

    func testMergeFallsBackToDiscoveredPlistAndFillsBlanks() throws {
        let real = try write("x.plist", ["Label": "com.ale.x", "StartInterval": 60, "StandardErrorPath": "/tmp/x.err"])
        let registry = [RoutineJob(label: "com.ale.x", name: "X", plist: "/nonexistent/x.plist")]
        let merged = RoutineDiscovery.merge(registry: registry, discovered: RoutineDiscovery.discover(agents: dir.path, prefixes: ["com.ale."]))
        XCTAssertEqual(merged[0].plist, real)
        XCTAssertTrue(merged[0].installed)
        XCTAssertEqual(merged[0].description, "a cada 1 min")
        XCTAssertEqual(merged[0].logs, ["/tmp/x.err"])
    }

    func testProfileDecodesNewKeysAndStaysCompatible() throws {
        let old = #"{"persona":{"name":"K","language":"pt-BR"},"agent":{"cwd":"~"},"blocks":{"routines":{"registry":"r","status":"s"}}}"#
        let a = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        XCTAssertNil(a.blocks?.routines?.prefixes)
        XCTAssertNil(a.blocks?.hooks)
        let new = #"{"persona":{"name":"K","language":"pt-BR"},"agent":{"cwd":"~"},"blocks":{"routines":{"prefixes":["a."],"agents":"/x"},"hooks":{"list":"l","disable":"d {id}","enable":"e {id}"},"commands":{"dirs":["~/b"]}}}"#
        let b = try JSONDecoder().decode(Profile.self, from: Data(new.utf8))
        XCTAssertEqual(b.blocks?.routines?.prefixes, ["a."])
        XCTAssertEqual(b.blocks?.routines?.agents, "/x")
        XCTAssertEqual(b.blocks?.hooks, HooksBlock(list: "l", disable: "d {id}", enable: "e {id}"))
        XCTAssertEqual(b.blocks?.commands?.dirs, ["~/b"])
    }
}
