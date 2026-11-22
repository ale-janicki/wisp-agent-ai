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
        var options = try BrainFiles.stagingFoldersForTesting(destination, root: vault.root)
        XCTAssertTrue(options.last?.hasPrefix(".wisp-tmp-") == true)
        XCTAssertFalse(options.contains { $0.hasPrefix("note-") })
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        options = try BrainFiles.stagingFoldersForTesting(destination, root: vault.root)
        XCTAssertTrue(options.contains { $0.hasPrefix("note-") })
        try BrainFiles(root: vault.path).write("after", to: "recipes/bread.md")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.root.appendingPathComponent(".git/wisp-tmp").path)
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertEqual(try vault.text("recipes/bread.md"), "after")
    }
}
