import XCTest
@testable import WispCore

final class RoutinesTests: XCTestCase {
    private let waiting = """
    gui/501/com.example.sync = {
    \tactive count = 0
    \tpath = /Users/u/Library/LaunchAgents/com.example.sync.plist
    \ttype = LaunchAgent
    \tstate = not running

    \tprogram = /usr/local/bin/sync
    \targuments = {
    \t\t/usr/local/bin/sync
    \t\tpull
    \t}

    \tstdout path = /tmp/sync.log
    \tenvironment = {
    \t\tPATH => /usr/bin:/bin
    \t\tstate = running
    \t}

    \tdomain = gui/501 [100027]
    \truns = 383
    \tlast exit code = 0

    \tresource coalition = {
    \t\tID = 956
    \t\tstate = active
    \t}

    \trun interval = 300 seconds
    \tjob state = exited
    }
    """

    private let running = """
    gui/501/com.example.bot = {
    \tactive count = 1
    \tstate = running

    \truns = 9
    \tpid = 32950
    \timmediate reason = inefficient
    \tlast exit code = 70: EX_SOFTWARE
    }
    """

    func testParsesWaitingJobTopLevelOnly() throws {
        let status = try XCTUnwrap(RoutineStatusParser.parse(waiting))
        XCTAssertEqual(status, RoutineStatus(state: .waiting, pid: nil, runs: 383, lastExitCode: 0, lastExitReason: nil))
        XCTAssertTrue(status.isLoaded)
        XCTAssertFalse(status.lastRunFailed)
    }

    func testParsesRunningJobWithExitReason() throws {
        let status = try XCTUnwrap(RoutineStatusParser.parse(running))
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 32950)
        XCTAssertEqual(status.runs, 9)
        XCTAssertEqual(status.lastExitCode, 70)
        XCTAssertEqual(status.lastExitReason, "EX_SOFTWARE")
        XCTAssertTrue(status.lastRunFailed)
    }

    func testNeverRunJobHasNoCounters() throws {
        let status = try XCTUnwrap(RoutineStatusParser.parse("gui/501/x = {\n\tstate = not running\n\tprogram = /bin/bash\n}\n"))
        XCTAssertEqual(status, RoutineStatus(state: .waiting))
        XCTAssertEqual(RoutineStatusParser.parse("gui/501/x = {\n\tstate = spawn scheduled\n}")?.state, .other("spawn scheduled"))
    }

    func testRejectsTextThatIsNotLaunchctlPrint() {
        XCTAssertNil(RoutineStatusParser.parse(""))
        XCTAssertNil(RoutineStatusParser.parse("Bad request.\nCould not find service"))
        XCTAssertNil(RoutineStatusParser.parse("gui/501/x = {\n\tpid = 3\n}"))
    }

    func testInterpretsNotLoadedExitAsUnloadedAndOtherFailuresAsErrors() {
        XCTAssertEqual(
            RoutineStatusParser.interpret(.failure(.failed(status: 113, message: "Bad request."))),
            .success(.unloaded)
        )
        XCTAssertEqual(
            RoutineStatusParser.interpret(.failure(.timedOut(seconds: 5))),
            .failure(RoutineStatusError("o comando passou de 5 s"))
        )
        XCTAssertEqual(RoutineStatusParser.interpret(.success(Data("nada".utf8))), .failure(RoutineStatusError("a saída do status não é a do launchctl print")))
        XCTAssertEqual(RoutineStatusParser.interpret(.success(Data(running.utf8))), .success(RoutineStatusParser.parse(running)!))
    }

    func testBuildsCommandsWithQuotedValues() {
        let job = RoutineJob(label: "com.example.sync", name: "Sync", plist: "/Users/u/Library/Launch Agents/it's.plist")
        XCTAssertEqual(RoutineCommand.build("launchctl print gui/{uid}/{label}", job: job, uid: 501), "launchctl print gui/501/'com.example.sync'")
        XCTAssertEqual(RoutineCommand.build("launchctl bootout gui/{uid}/{label}", job: job, uid: 501), "launchctl bootout gui/501/'com.example.sync'")
        XCTAssertEqual(
            RoutineCommand.build("launchctl bootstrap gui/{uid} {plist}", job: job, uid: 501),
            #"launchctl bootstrap gui/501 '/Users/u/Library/Launch Agents/it'\''s.plist'"#
        )
        XCTAssertTrue(RoutineCommand.build("{uid}", job: job).allSatisfy(\.isNumber))
    }

    func testParsesRegistryExpandingTildeAndDefaults() throws {
        let json = #"""
        {"jobs":[
          {"label":"com.example.a","name":"Sincronizar","description":"Puxa a cada 5 min","plist":"~/Library/LaunchAgents/com.example.a.plist","logs":["~/a.log","/tmp/a.err"]},
          {"label":"com.example.b","plist":"/p/b.plist"}
        ]}
        """#
        let jobs = try RoutineRegistry.parse(Data(json.utf8))
        XCTAssertEqual(jobs.map(\.id), ["com.example.a", "com.example.b"])
        XCTAssertEqual(jobs[0].plist, NSHomeDirectory() + "/Library/LaunchAgents/com.example.a.plist")
        XCTAssertEqual(jobs[0].logs, [NSHomeDirectory() + "/a.log", "/tmp/a.err"])
        XCTAssertEqual(jobs[1].name, "com.example.b")
        XCTAssertEqual(jobs[1].logs, [])
        XCTAssertNil(jobs[1].description)
        XCTAssertThrowsError(try RoutineRegistry.parse(Data("[1]".utf8))) { XCTAssertEqual($0 as? RoutineRegistryError, .invalid) }
        XCTAssertThrowsError(try RoutineRegistry.load(path: "/nao/existe.json"))
    }

    func testReadsLogPathsFromPlistWithoutRepeats() throws {
        let same = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "x", "StandardOutPath": "/tmp/x.log", "StandardErrorPath": "/tmp/x.log"], format: .xml, options: 0)
        XCTAssertEqual(RoutineRegistry.logs(fromPlist: same), ["/tmp/x.log"])
        let split = try PropertyListSerialization.data(
            fromPropertyList: ["StandardOutPath": "/tmp/x.out", "StandardErrorPath": "~/x.err"], format: .xml, options: 0)
        XCTAssertEqual(RoutineRegistry.logs(fromPlist: split), ["/tmp/x.out", NSHomeDirectory() + "/x.err"])
        XCTAssertEqual(RoutineRegistry.logs(fromPlist: Data("nope".utf8)), [])
    }

    func testRegistryFixtureMatchesItsPlist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("routines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plistURL = dir.appendingPathComponent("job.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.wisp-job", "StandardOutPath": "/tmp/job.log"], format: .xml, options: 0)
        try plistData.write(to: plistURL)
        let registry = dir.appendingPathComponent("jobs.json")
        let json = #"{"jobs":[{"label":"com.example.wisp-job","name":"Job","plist":"\#(plistURL.path)","logs":["/tmp/job.log"]}]}"#
        try Data(json.utf8).write(to: registry)
        for job in try RoutineRegistry.load(path: registry.path) {
            let data = try XCTUnwrap(FileManager.default.contents(atPath: job.plist), job.label)
            XCTAssertEqual(RoutineRegistry.logs(fromPlist: data), job.logs, job.label)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["Label"] as? String, job.label)
        }
    }

    func testProfileDecodesMemoryAndRoutinesBlocks() throws {
        let json = #"""
        {"persona":{"name":"A","language":"en"},"agent":{"cwd":"~"},"blocks":{
          "memory":{"root":"~/notas","search":"grep -e {query} {root}"},
          "routines":{"registry":"~/jobs.json","status":"launchctl print gui/{uid}/{label}"}}}
        """#
        let blocks = try XCTUnwrap(try JSONDecoder().decode(Profile.self, from: Data(json.utf8)).blocks)
        XCTAssertEqual(blocks.memory, MemoryBlock(root: "~/notas", search: "grep -e {query} {root}"))
        XCTAssertEqual(blocks.routines, RoutinesBlock(registry: "~/jobs.json", status: "launchctl print gui/{uid}/{label}"))
        XCTAssertNil(blocks.routines?.start)
    }

    func testRealLaunchctlPrintReportsAnUnloadedJob() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISP_LIVE"] == "1")
        let missing = RoutineJob(label: "com.example.wisp-not-loaded", name: "x", plist: "/x.plist")
        let command = RoutineCommand.build("launchctl print gui/{uid}/{label}", job: missing)
        XCTAssertEqual(RoutineStatusParser.interpret(BlockCommand.run(command, path: "/usr/bin:/bin")), .success(.unloaded))
    }

    func testLogTailReadsLastLinesFromTheEnd() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (1...200).map { "linha \($0)" }.joined(separator: "\n") + "\n\n"
        try Data(body.utf8).write(to: url)

        XCTAssertEqual(try LogTail.read(path: url.path, count: 3).get(), ["linha 198", "linha 199", "linha 200"])
        let window = try LogTail.read(path: url.path, count: 50, maxBytes: 25).get()
        XCTAssertEqual(window, ["linha 199", "linha 200"])
        XCTAssertEqual(LogTail.read(path: "/nao/existe.log"), .failure(.missing("/nao/existe.log")))
        XCTAssertEqual(LogTail.lastLines(of: Data(), count: 50, truncatedStart: false), [])
        XCTAssertEqual(LogTail.lastLines(of: Data("a\r\nb\r\n".utf8), count: 50, truncatedStart: false), ["a", "b"])
    }
}
