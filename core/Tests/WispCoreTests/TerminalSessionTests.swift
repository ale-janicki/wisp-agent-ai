import XCTest
@testable import WispCore

@MainActor
final class FakeTerminalEngine: TerminalEngine {
    var onOutput: (@Sendable () -> Void)?
    var onExit: (@MainActor (Int32?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var settledBy: Date?
    var onDirectory: (@MainActor (String) -> Void)?
    var onTitle: (@MainActor (String) -> Void)?
    var onShellEvents: (@MainActor ([StampedShellEvent]) -> Void)?

    var started: (shell: TerminalShell, cwd: String, env: [String: String], size: TerminalSize, launch: TerminalLaunch)?
    var written = [UInt8]()
    var sizes = [TerminalSize]()
    var terminated = false
    var failure: Error?
    var liveDirectory: String?
    var bracketedPasteMode = false

    func start(shell: TerminalShell, launch: TerminalLaunch, cwd: String, size: TerminalSize) throws {
        if let failure { throw failure }
        started = (shell, cwd, launch.environment, size, launch)
    }

    func write(_ bytes: [UInt8]) { written += bytes }
    func resize(_ size: TerminalSize) { sizes.append(size) }
    func terminate() { terminated = true }
    func settle(by deadline: Date) { settledBy = deadline }
    func currentDirectory() -> String? { liveDirectory }
}

@MainActor
final class TerminalSessionTests: XCTestCase {
    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private var engines = [FakeTerminalEngine]()

    private func session(directory: String = "/home/dev", home: String = "/home/dev") -> TerminalSession {
        TerminalSession(shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": home], directory: directory) { [unowned self] in
            let engine = FakeTerminalEngine()
            engines.append(engine)
            return engine
        }
    }

    func testStartRunsTheLoginShellInTheDirectory() throws {
        let session = session(directory: "/tmp")
        session.start(size: TerminalSize(columns: 100, rows: 30))
        XCTAssertEqual(session.phase, .running)
        let started = try XCTUnwrap(engines[0].started)
        XCTAssertEqual(started.cwd, "/tmp")
        XCTAssertEqual(started.shell.loginName, "-zsh")
        XCTAssertEqual(started.size, TerminalSize(columns: 100, rows: 30))
    }

    func testExitEndsTheSessionAndKeepsTheCode() {
        let session = session()
        session.start()
        engines[0].onExit?(3)
        XCTAssertEqual(session.phase, .ended(3))
        engines[0].written = []
        session.write([1])
        XCTAssertTrue(engines[0].written.isEmpty, "nothing is written to a shell that ended")
    }

    func testReopenStartsAFreshEngineInTheLastDirectory() throws {
        let session = session()
        session.start()
        engines[0].onDirectory?("/tmp/work")
        engines[0].onExit?(nil)
        XCTAssertEqual(session.phase, .ended(nil))
        session.reopen()
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(try XCTUnwrap(engines[1].started).cwd, "/tmp/work")
        engines[0].onExit?(9)
        XCTAssertEqual(session.phase, .running, "the old engine no longer speaks for the session")
    }

    func testReopenDoesNothingWhileRunning() {
        let session = session()
        session.start()
        session.reopen()
        XCTAssertEqual(engines.count, 1)
    }

    func testStartFailureIsReportedAndCanBeReopened() {
        let session = session()
        let first = engines[0]
        first.failure = Boom()
        session.start()
        XCTAssertEqual(session.phase, .failed("Não abriu o shell: boom"))
        session.reopen()
        XCTAssertEqual(session.phase, .running)
    }

    func testALaunchFailureReportedByTheEngineIsAFailureNotAnExit() {
        let session = session()
        session.start()
        engines[0].onFailure?("forkFailed(35)")
        XCTAssertEqual(session.phase, .failed("Não abriu o shell: forkFailed(35)"))
        session.reopen()
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(engines.count, 2)
    }

    func testResizeReachesTheEngineOnlyWhileRunning() {
        let session = session()
        session.resize(TerminalSize(columns: 50, rows: 10))
        XCTAssertTrue(engines[0].sizes.isEmpty)
        session.start()
        session.resize(TerminalSize(columns: 120, rows: 40))
        XCTAssertEqual(engines[0].sizes, [TerminalSize(columns: 120, rows: 40)])
    }

    func testCloseTerminatesAndIgnoresTheLateExit() {
        let session = session()
        session.start()
        session.close()
        XCTAssertTrue(engines[0].terminated)
        engines[0].onExit?(0)
        XCTAssertEqual(session.phase, .idle)
    }

    func testNameIsTheTitleThenTheFolderThenTheShell() {
        let session = session(directory: "/home/dev", home: "/home/dev")
        XCTAssertEqual(session.name, "~")
        session.start()
        engines[0].onDirectory?("file://mac.local/home/dev/my%20project")
        XCTAssertEqual(session.directory, "/home/dev/my project")
        XCTAssertEqual(session.name, "my project")
        engines[0].onTitle?("vim notes.md")
        XCTAssertEqual(session.name, "vim notes.md")
        XCTAssertEqual(TerminalSessionName.make(title: "", directory: nil, home: nil, shell: TerminalShell(path: "/bin/zsh")), "zsh")
        XCTAssertEqual(TerminalSessionName.make(title: "  ", directory: "/", home: "/home/dev", shell: TerminalShell(path: "/bin/zsh")), "/")
    }

    func testRefreshDirectoryReadsTheSystemOnce() {
        let session = session()
        session.start()
        engines[0].liveDirectory = "/var/tmp"
        var reported = [String]()
        session.onDirectory = { reported.append($0) }
        session.refreshDirectory()
        session.refreshDirectory()
        XCTAssertEqual(session.directory, "/var/tmp")
        XCTAssertEqual(reported, ["/var/tmp"])
    }
}

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
    private var engines = [FakeTerminalEngine]()
    private var saved: String?
    private var directories = [String]()

    private func workspace(remembered: String? = nil, existing: Set<String> = []) -> TerminalWorkspace {
        saved = remembered
        let memory = TerminalDirectory.Memory(load: { [unowned self] in saved }, save: { [unowned self] in saved = $0 }, isDirectory: { existing.contains($0) })
        return TerminalWorkspace(memory: memory, home: "/home/dev") { [unowned self] directory in
            directories.append(directory)
            return TerminalSession(shell: TerminalShell(path: "/bin/zsh"), environment: ["HOME": "/home/dev"], directory: directory) { [unowned self] in
                let engine = FakeTerminalEngine()
                engines.append(engine)
                return engine
            }
        }
    }

    func testFirstSessionOpensOnceAndStartsInHomeWithoutMemory() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        workspace.openFirstIfNeeded()
        XCTAssertEqual(workspace.sessions.count, 1)
        XCTAssertEqual(directories, ["/home/dev"])
        XCTAssertEqual(workspace.selectedID, workspace.sessions[0].id)
        XCTAssertTrue(workspace.sessions[0].isRunning)
    }

    func testStartsInTheRememberedDirectoryWhenItStillExists() {
        let kept = workspace(remembered: "/home/dev/code", existing: ["/home/dev/code"])
        kept.openFirstIfNeeded()
        XCTAssertEqual(directories, ["/home/dev/code"])
        directories = []
        let gone = workspace(remembered: "/home/dev/deleted", existing: [])
        gone.openFirstIfNeeded()
        XCTAssertEqual(directories, ["/home/dev"])
    }

    func testDirectoryReportsAreRemembered() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        engines[0].onDirectory?("/home/dev/repo")
        XCTAssertEqual(saved, "/home/dev/repo")
    }

    func testRememberDirectoriesReadsTheSelectedShell() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        engines[0].liveDirectory = "/home/dev/live"
        workspace.rememberDirectories()
        XCTAssertEqual(saved, "/home/dev/live")
    }

    func testNewSessionStartsWhereTheSelectedOneIs() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        engines[0].onDirectory?("/home/dev/repo")
        workspace.openSession()
        XCTAssertEqual(directories.last, "/home/dev/repo")
        XCTAssertEqual(workspace.sessions.count, 2)
        XCTAssertEqual(workspace.selectedID, workspace.sessions[1].id)
    }

    func testClosingTheSelectedSessionSelectsANeighbourAndEndsItsShell() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        workspace.openSession()
        workspace.openSession()
        let ids = workspace.sessions.map(\.id)
        workspace.select(ids[1])
        XCTAssertTrue(workspace.closeSelected())
        XCTAssertTrue(engines[1].terminated)
        XCTAssertEqual(workspace.sessions.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(workspace.selectedID, ids[2])
    }

    func testClosingTheLastSessionLeavesTheTabEmptyAndTheNextCloseFree() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        XCTAssertTrue(workspace.closeSelected())
        XCTAssertTrue(workspace.sessions.isEmpty)
        XCTAssertNil(workspace.selectedID)
        workspace.openFirstIfNeeded()
        XCTAssertTrue(workspace.sessions.isEmpty, "a closed tab does not reopen by itself")
        XCTAssertFalse(workspace.closeSelected(), "with no session the key is the window's")
    }

    func testSelectIgnoresUnknownIDs() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        let id = workspace.selectedID
        workspace.select(UUID())
        XCTAssertEqual(workspace.selectedID, id)
    }

    func testCloseAllEndsEveryShell() {
        let workspace = workspace()
        workspace.openFirstIfNeeded()
        workspace.openSession()
        workspace.closeAll()
        XCTAssertTrue(engines.allSatisfy(\.terminated))
        XCTAssertTrue(workspace.sessions.isEmpty)
        let deadlines = engines.compactMap(\.settledBy)
        XCTAssertEqual(deadlines.count, 2, "every running shell gets the quit grace")
        XCTAssertEqual(Set(deadlines).count, 1, "all of them share one deadline")
        XCTAssertLessThan(deadlines[0].timeIntervalSinceNow, 0.6)
    }
}

final class TerminalDirectoryTests: XCTestCase {
    func testReportParsing() {
        XCTAssertEqual(TerminalDirectory.path(fromReport: "file:///home/dev/x"), "/home/dev/x")
        XCTAssertEqual(TerminalDirectory.path(fromReport: "file://host.local/home/dev/x%20y"), "/home/dev/x y")
        XCTAssertEqual(TerminalDirectory.path(fromReport: "/already/a/path"), "/already/a/path")
        XCTAssertNil(TerminalDirectory.path(fromReport: "https://example.com/x"))
        XCTAssertNil(TerminalDirectory.path(fromReport: "relative/path"))
        XCTAssertNil(TerminalDirectory.path(fromReport: ""))
        XCTAssertNil(TerminalDirectory.path(fromReport: nil))
    }

    func testRememberIgnoresRelativePathsAndRepeats() {
        var saves = [String]()
        let memory = TerminalDirectory.Memory(load: { saves.last }, save: { saves.append($0) }, isDirectory: { _ in true })
        memory.remember("relative")
        memory.remember("/a")
        memory.remember("/a")
        memory.remember("/b")
        XCTAssertEqual(saves, ["/a", "/b"])
    }

    func testProcessDirectoryOfThisProcess() throws {
        let reported = try XCTUnwrap(TerminalDirectory.ofProcess(getpid()))
        XCTAssertEqual(
            URL(fileURLWithPath: reported).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertNil(TerminalDirectory.ofProcess(0))
    }
}
