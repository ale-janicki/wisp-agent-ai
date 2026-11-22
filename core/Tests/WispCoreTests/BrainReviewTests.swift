import XCTest
@testable import WispCore

final class BrainReviewTests: XCTestCase {
    func testCrlfMergeWorksPerLine() {
        let base = "a\r\nb\r\nc\r\nd\r\ne", mine = "a\r\nB\r\nc\r\nd\r\ne", theirs = "a\r\nb\r\nc\r\nD\r\ne"
        XCTAssertEqual(BrainMerge.merge(base: base, mine: mine, theirs: theirs), .merged("a\r\nB\r\nc\r\nD\r\ne"))
        XCTAssertEqual(BrainMerge.merge(base: base, mine: base, theirs: theirs), .reload(theirs))
        let marked = BrainMerge.merge(base: "a\r\nb\r\nc", mine: "a\r\nx\r\nc", theirs: "a\r\ny\r\nc")
        guard case .conflict(let text) = marked else { return XCTFail("expected a conflict") }
        XCTAssertTrue(BrainMerge.hasMarkers(text))
    }

    func testCrlfTaskTogglesPastTheFirstLine() {
        let text = "- [ ] a\r\n- [ ] b\r\n- [x] c\r\n"
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 1, expected: "- [ ] b"), "- [ ] a\r\n- [x] b\r\n- [x] c\r\n")
        XCTAssertEqual(BrainTasks.toggle(in: text, line: 2), "- [ ] a\r\n- [ ] b\r\n- [ ] c\r\n")
    }

    func testCrlfFrontmatterIsDetectedEditedAndKeptCrlf() {
        let source = "---\r\ntags: [a]\r\nstatus: active\r\n---\r\n# T\r\n"
        var document = BrainDocument(source)
        XCTAssertTrue(document.hasFrontmatter)
        XCTAssertEqual(document.text, source)
        XCTAssertEqual(document.list("tags"), ["a"])
        XCTAssertEqual(document.property("status"), .text("active"))
        document.set("status", to: .text("done"))
        document.set("aliases", to: .list(["x"]))
        XCTAssertEqual(document.text, "---\r\ntags: [a]\r\nstatus: done\r\naliases:\r\n  - x\r\n---\r\n# T\r\n")
    }

    func testCrlfNotesParseWithTheRightLinesAndScanFrontmatter() {
        let text = "---\r\naliases: [Al]\r\n---\r\n# Title\r\n\r\n- [ ] one\r\n"
        let model = BrainMarkdown.parse(text)
        XCTAssertEqual(model.headings.map(\.line), [3])
        guard case .list(_, _, let items) = model.nodes[1].block else { return XCTFail("no list") }
        XCTAssertEqual(items[0].line, 5)
        XCTAssertEqual(items[0].raw, "- [ ] one")
        XCTAssertEqual(BrainTasks.toggle(in: text, line: items[0].line, expected: items[0].raw), "---\r\naliases: [Al]\r\n---\r\n# Title\r\n\r\n- [x] one\r\n")
        let note = BrainNoteParser.parse(Array(text.utf8), path: "n.md")
        XCTAssertEqual(note?.aliases, ["Al"])
        XCTAssertEqual(note?.title, "Title")
    }

    func testPresenceTellsAbsentFromUnreadable() throws {
        let vault = try BrainVaultFixture()
        try Data([0xFF, 0xFE]).write(to: vault.root.appendingPathComponent("bad.md"))
        let files = BrainFiles(root: vault.path)
        XCTAssertEqual(files.presence("index.md"), .text(try vault.text("index.md")))
        XCTAssertEqual(files.presence("gone.md"), .absent)
        XCTAssertEqual(files.presence("bad.md"), .unreadable)
    }

    func testHardLinkedNotesAreReadOnlyAndNeverReplaced() throws {
        let vault = try BrainVaultFixture()
        let original = vault.root.appendingPathComponent("recipes/bread.md").path
        XCTAssertEqual(link(original, vault.root.appendingPathComponent("twin.md").path), 0)
        let files = BrainFiles(root: vault.path)
        XCTAssertTrue(files.isHardLinked("twin.md"))
        XCTAssertTrue(files.sameFile("twin.md", "recipes/bread.md"))
        XCTAssertFalse(files.sameFile("twin.md", "index.md"))
        XCTAssertNotNil(files.writeProblem("twin.md"))
        XCTAssertThrowsError(try files.write("x", to: "twin.md"))
        let before = try vault.text("recipes/bread.md")
        XCTAssertEqual(try vault.text("twin.md"), before)
        let plan = try BrainRefactor.plan(root: vault.path, scan: vault.scan(), from: "recipes/apple-pie.md", to: "recipes/tart.md")
        XCTAssertTrue(plan.skipped.contains("twin.md") || plan.skipped.contains("recipes/bread.md"))
    }

    func testRewriteKeepsTheBirthtimeAndLeavesNoTempInsideTheBrain() throws {
        let vault = try BrainVaultFixture()
        let path = vault.root.appendingPathComponent("recipes/bread.md").path
        var before = stat()
        stat(path, &before)
        Thread.sleep(forTimeInterval: 1.1)
        try BrainFiles(root: vault.path).write("new text", to: "recipes/bread.md")
        var after = stat()
        stat(path, &after)
        XCTAssertEqual(before.st_birthtimespec.tv_sec, after.st_birthtimespec.tv_sec)
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent("recipes").path)
        XCTAssertFalse(names.contains { $0.contains("wisp") })
    }

    func testCaseOnlyRenameWorksButAnotherFileIsNeverOverwritten() throws {
        let vault = try BrainVaultFixture()
        let files = BrainFiles(root: vault.path)
        try files.move("recipes/bread.md", to: "recipes/Bread.md")
        XCTAssertTrue(files.exists("recipes/Bread.md"))
        XCTAssertThrowsError(try files.move("recipes/Bread.md", to: "recipes/apple-pie.md")) { XCTAssertEqual($0 as? BrainFilesError, .exists("recipes/apple-pie.md")) }
        let scan = try vault.scan()
        XCTAssertThrowsError(try BrainRefactor.plan(root: vault.path, scan: scan, from: "index.md", to: "Index.md".replacingOccurrences(of: "Index", with: "projects/notes")))
        XCTAssertNoThrow(try BrainRefactor.plan(root: vault.path, scan: scan, from: "recipes/Bread.md", to: "recipes/bread.md"))
    }
}

final class BrainFallbackTests: XCTestCase {
    func testConflictMarkersUseCrlfInACrlfFile() {
        let outcome = BrainMerge.merge(base: "a\r\nb\r\nc", mine: "a\r\nx\r\nc", theirs: "a\r\ny\r\nc")
        guard case .conflict(let text) = outcome else { return XCTFail("expected a conflict") }
        XCTAssertEqual(text, "a\r\n<<<<<<< minhas edições\r\nx\r\n=======\r\ny\r\n>>>>>>> no disco\r\nc")
        XCTAssertTrue(BrainMerge.hasMarkers(text))
        guard case .conflict(let plain) = BrainMerge.merge(base: "a\nb\nc", mine: "a\nx\nc", theirs: "a\ny\nc") else { return XCTFail("expected a conflict") }
        XCTAssertFalse(plain.contains("\r"))
    }

    func testCaseOnlyRenameLooksAtTheLinkItselfAndRequiresCaseOnlyNames() throws {
        let vault = try BrainVaultFixture(["target.md": "# T\n"])
        try FileManager.default.createSymbolicLink(atPath: vault.root.appendingPathComponent("link.md").path, withDestinationPath: "target.md")
        let files = BrainFiles(root: vault.path)
        XCTAssertFalse(files.sameFile("link.md", "target.md"))
        XCTAssertFalse(files.isCaseOnlyRename("link.md", "target.md"))
        XCTAssertFalse(files.isCaseOnlyRename("target.md", "target.md"))
        XCTAssertTrue(files.isCaseOnlyRename("target.md", "Target.md") || !files.exists("Target.md"))
        XCTAssertThrowsError(try files.move("link.md", to: "target.md"))
    }

    func testStagingFallsBackToGitFolderThenToAHiddenSiblingNamedWispTmp() throws {
        let vault = try BrainVaultFixture()
        let destination = vault.root.appendingPathComponent("recipes/bread.md")
        var options = BrainFiles.stagingFoldersForTesting(destination, root: vault.root)
        XCTAssertTrue(options.last?.hasPrefix(".wisp-tmp-") == true)
        XCTAssertFalse(options.contains { $0.hasPrefix("note-") })
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        options = BrainFiles.stagingFoldersForTesting(destination, root: vault.root)
        XCTAssertTrue(options.contains { $0.hasPrefix("note-") })
        try BrainFiles(root: vault.path).write("after", to: "recipes/bread.md")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent(".git/wisp-tmp").path)
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertEqual(try vault.text("recipes/bread.md"), "after")
    }
}

final class BrainFallbackInjectionTests: XCTestCase {
    override func tearDown() {
        BrainFiles.failSystemStaging = false
        BrainFiles.exdevFromSystemStaging = false
        super.tearDown()
    }

    func testFailingSystemFolderFallsBackToGitThenToTheSibling() throws {
        let vault = try BrainVaultFixture()
        let files = BrainFiles(root: vault.path)
        BrainFiles.failSystemStaging = true
        try files.write("one", to: "recipes/bread.md")
        XCTAssertEqual(BrainFiles.lastStaging, "sibling")
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try files.write("two", to: "recipes/bread.md")
        XCTAssertEqual(BrainFiles.lastStaging, "git")
        XCTAssertEqual(try vault.text("recipes/bread.md"), "two")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent(".git/wisp-tmp").path).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent("recipes").path).contains { $0.hasPrefix(".wisp-tmp-") })
    }

    func testExdevOnTheSystemFolderRenameFallsBackAndTheNoteIsWritten() throws {
        let vault = try BrainVaultFixture()
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        BrainFiles.exdevFromSystemStaging = true
        try BrainFiles(root: vault.path).write("moved across volumes", to: "index.md")
        XCTAssertEqual(BrainFiles.lastStaging, "git")
        XCTAssertEqual(try vault.text("index.md"), "moved across volumes")
    }

    func testStaleTempsAreSweptByChangeTimeAndOnlyRegularFiles() throws {
        let vault = try BrainVaultFixture()
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".git/wisp-tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent("recipes/.wisp-tmp-dir"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: vault.root.appendingPathComponent("recipes/.wisp-tmp-dir/keep"))
        for path in ["recipes/.wisp-tmp-old", ".git/wisp-tmp/note-old", "recipes/keep.md"] {
            try Data("x".utf8).write(to: vault.root.appendingPathComponent(path))
        }
        Thread.sleep(forTimeInterval: 1.3)
        for path in ["recipes/.wisp-tmp-new", ".git/wisp-tmp/note-new"] {
            try Data("x".utf8).write(to: vault.root.appendingPathComponent(path))
        }
        let ancient = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: vault.root.appendingPathComponent("recipes/.wisp-tmp-new").path)
        XCTAssertEqual(BrainFiles.removeStaleTemps(root: vault.path, olderThan: 1), 2)
        let present = { (path: String) in FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(path).path) }
        XCTAssertFalse(present("recipes/.wisp-tmp-old") || present(".git/wisp-tmp/note-old"))
        XCTAssertTrue(present("recipes/.wisp-tmp-new"), "a fresh temp with an old mtime must survive")
        XCTAssertTrue(present(".git/wisp-tmp/note-new") && present("recipes/keep.md"))
        XCTAssertTrue(present("recipes/.wisp-tmp-dir/keep"), "a directory with that name is never removed")
        XCTAssertEqual(BrainFiles.removeStaleTemps(root: vault.path, olderThan: 1, now: Date().addingTimeInterval(600)), 2)
        XCTAssertTrue(present("recipes/.wisp-tmp-dir/keep"))
    }

    func testASavedNoteGetsTheTimeOfTheSaveNotTheOldOne() throws {
        let vault = try BrainVaultFixture()
        let path = vault.root.appendingPathComponent("recipes/bread.md").path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: path)
        try BrainFiles(root: vault.path).write("edited", to: "recipes/bread.md")
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 10)
    }

    func testEveryStagingErrorIsReported() throws {
        let vault = try BrainVaultFixture()
        BrainFiles.failSystemStaging = true
        let blocked = vault.root.appendingPathComponent("recipes")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        try? FileManager.default.removeItem(at: vault.root.appendingPathComponent(".git"))
        XCTAssertThrowsError(try BrainFiles(root: vault.path).write("x", to: "recipes/new.md")) { error in
            XCTAssertTrue(error.localizedDescription.contains("sibling:"))
        }
    }
}

final class TerminationSignalTests: XCTestCase {
    private var previous = sigaction()

    override func setUp() {
        super.setUp()
        sigaction(SIGTERM, nil, &previous)
        TerminationSignal.routeToHandler()
    }

    override func tearDown() {
        sigaction(SIGTERM, &previous, nil)
        super.tearDown()
    }

    func testFoundationProcessChildrenStillDieOnTerminate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5"]
        try process.run()
        let start = Date()
        process.terminate()
        process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    private func diesOfSigterm(_ pid: pid_t) -> Bool {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<100 {
            if waitpid(pid, &status, WNOHANG) == pid { return status & 0x7f == SIGTERM }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
        return false
    }

    func testSpawnedChildrenDieOfSigtermNotOfTheFallbackKill() throws {
        let pipe = Pipe()
        let pid = try ProcessCore.spawn("/bin/sh", arguments: ["-c", "sleep 5"], environment: [:], stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertTrue(diesOfSigterm(pid))
    }

    func testIgnoredTermInTheParentDoesNotLeakIntoSpawnedChildren() throws {
        signal(SIGTERM, SIG_IGN)
        let pipe = Pipe()
        let pid = try ProcessCore.spawn("/bin/sh", arguments: ["-c", "sleep 5"], environment: [:], stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertTrue(diesOfSigterm(pid))
    }
}
